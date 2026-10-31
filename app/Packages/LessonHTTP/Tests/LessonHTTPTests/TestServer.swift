import CryptoKit
import Foundation
import LessonHTTP
import NIOCore
import NIOHTTP1
import NIOPosix
import Synchronization
import Testing
import zlib

/// One request as a test server saw it.
struct Received: Sendable {
    var method: String
    var uri: String
    var headers: [(name: String, value: String)]
    var body: Data

    /// The header lines in order, as "Name: value".
    var lines: [String] { headers.map { "\($0.name): \($0.value)" } }

    func value(_ name: String) -> String? {
        headers.first { $0.name.lowercased() == name.lowercased() }?.value
    }

    func count(_ name: String) -> Int {
        headers.count { $0.name.lowercased() == name.lowercased() }
    }
}

/// How the test server answers.
enum Reply: Sendable {
    /// A whole response; a Content-Length is added unless given.
    case full(status: Int, headers: [(String, String)], body: [UInt8])
    /// A chunked body, one chunk per element, then trailers.
    case chunked(headers: [(String, String)], chunks: [[UInt8]], trailers: [(String, String)])
    /// The head and the start of the body, then nothing more.
    case stall(headers: [(String, String)], body: [UInt8])
    /// No answer at all.
    case silence
}

/// A local HTTP/1.1 server on a loopback address and a free port. It records every request
/// and answers by path; see `reply(to:)`.
final class TestServer: Sendable {
    let host: String
    let port: Int
    private let channel: any Channel
    private let log: ServerLog

    private init(host: String, port: Int, channel: any Channel, log: ServerLog) {
        self.host = host
        self.port = port
        self.channel = channel
        self.log = log
    }

    static func start(host: String = "127.0.0.1") async throws -> TestServer {
        let log = ServerLog()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    // Without pipelining assistance the server keeps reading while a response is
                    // pending, so it sees a client close the connection.
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withPipeliningAssistance: false)
                    try channel.pipeline.syncOperations.addHandler(ServerHandler(log: log))
                }
            }
            .bind(host: host, port: 0)
            .get()
        let port = try #require(channel.localAddress?.port)
        return TestServer(host: host, port: port, channel: channel, log: log)
    }

    var authority: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }

    func url(_ path: String, scheme: String = "http") throws -> URL {
        try #require(URL(string: "\(scheme)://\(authority)\(path)"))
    }

    var requests: [Received] { log.requests }
    var closedConnections: Int { log.closed }

    func stop() async throws {
        try await channel.close()
    }

    /// The answer for each path the tests use.
    static func reply(to request: Received) -> Reply {
        let parts = URLComponents(string: "http://test\(request.uri)")
        let segments = (parts?.path ?? "").split(separator: "/").map(String.init)
        let query = parts?.queryItems ?? []
        let number = Int(segments.last ?? "") ?? 0
        switch segments.first {
        case "httpbin":
            // /httpbin/range/{n}: n bytes in 1 KiB chunks, then their SHA-256 and length as trailers.
            let bytes = rangeBytes(number)
            let chunks = stride(from: 0, to: bytes.count, by: 1024).map { Array(bytes[$0..<min($0 + 1024, bytes.count)]) }
            return .chunked(
                headers: [("Content-Type", "application/octet-stream"), ("Trailer", "X-Content-Sha256, X-Content-Length")],
                chunks: chunks,
                trailers: [("X-Content-Sha256", sha256Hex(bytes)), ("X-Content-Length", String(bytes.count))]
            )
        case "redirect":
            if number == 0 {
                return .full(status: 200, headers: [("Content-Type", "text/plain")], body: Array("done".utf8))
            }
            return .full(status: 302, headers: [("Location", "/redirect/\(number - 1)")], body: Array("redirecting".utf8))
        case "status":
            let location = query.first { $0.name == "location" }?.value
            return .full(status: number, headers: location.map { [("Location", $0)] } ?? [], body: Array("status \(number)".utf8))
        case "echo":
            return .full(status: 200, headers: [("Content-Type", "application/octet-stream")], body: Array(request.body))
        case "head":
            let body = request.method == "HEAD" ? [] : [UInt8](repeating: UInt8(ascii: "h"), count: 1234)
            return .full(status: 200, headers: [("Content-Type", "text/plain"), ("Content-Length", "1234")], body: body)
        case "gzip":
            let compressed = Array(gzipped(Data(gzipText.utf8)))
            if query.contains(where: { $0.name == "chunked" }) {
                let chunks = stride(from: 0, to: compressed.count, by: 700).map { Array(compressed[$0..<min($0 + 700, compressed.count)]) }
                return .chunked(headers: [("Content-Type", "text/plain"), ("Content-Encoding", "gzip")], chunks: chunks, trailers: [])
            }
            return .full(status: 200, headers: [("Content-Type", "text/plain"), ("Content-Encoding", "gzip")], body: compressed)
        case "stall":
            return .stall(headers: [("Content-Length", "100")], body: Array(repeating: UInt8(ascii: "s"), count: 10))
        case "silence":
            return .silence
        default:
            return .full(status: 200, headers: [("Content-Type", "text/plain")], body: Array("ok".utf8))
        }
    }
}

final class ServerLog: Sendable {
    private let state = Mutex<(requests: [Received], closed: Int)>(([], 0))

    func record(_ request: Received) { state.withLock { $0.requests.append(request) } }
    func connectionClosed() { state.withLock { $0.closed += 1 } }
    var requests: [Received] { state.withLock { $0.requests } }
    var closed: Int { state.withLock { $0.closed } }
}

final class ServerHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let log: ServerLog
    private var head: HTTPRequestHead?
    private var body = ByteBuffer()

    init(log: ServerLog) {
        self.log = log
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body.clear()
        case .body(var part):
            body.writeBuffer(&part)
        case .end:
            guard let head else { return }
            let request = Received(
                method: head.method.rawValue,
                uri: head.uri,
                headers: head.headers.map { (name: $0.name, value: $0.value) },
                body: Data(body.readableBytesView)
            )
            log.record(request)
            respond(TestServer.reply(to: request), context: context)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        log.connectionClosed()
        context.fireChannelInactive()
    }

    private func respond(_ reply: Reply, context: ChannelHandlerContext) {
        let channel = context.channel
        func writeHead(_ status: Int, _ fields: [(String, String)]) {
            let head = HTTPResponseHead(version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: HTTPHeaders(fields))
            context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
        }
        func writeBody(_ bytes: [UInt8]) {
            context.writeAndFlush(Self.wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: bytes)))), promise: nil)
        }
        switch reply {
        case .full(let status, var fields, let bytes):
            if !fields.contains(where: { $0.0.lowercased() == "content-length" }) {
                fields.append(("Content-Length", String(bytes.count)))
            }
            writeHead(status, fields)
            if !bytes.isEmpty { writeBody(bytes) }
            context.writeAndFlush(Self.wrapOutboundOut(.end(nil))).whenComplete { _ in channel.close(promise: nil) }
        case .chunked(let fields, let chunks, let trailers):
            writeHead(200, fields + [("Transfer-Encoding", "chunked")])
            chunks.forEach(writeBody)
            let end = trailers.isEmpty ? nil : HTTPHeaders(trailers)
            context.writeAndFlush(Self.wrapOutboundOut(.end(end))).whenComplete { _ in channel.close(promise: nil) }
        case .stall(let fields, let bytes):
            writeHead(200, fields)
            writeBody(bytes)
        case .silence:
            break
        }
    }
}

/// A TCP server that answers the first request on each connection with fixed bytes, for
/// responses an HTTP server library would not send.
final class RawServer: Sendable {
    let port: Int
    private let channel: any Channel

    private init(port: Int, channel: any Channel) {
        self.port = port
        self.channel = channel
    }

    static func start(answer: String, thenClose: Bool = true) async throws -> RawServer {
        let bytes = Array(answer.utf8)
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(RawHandler(answer: bytes, thenClose: thenClose))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(channel.localAddress?.port)
        return RawServer(port: port, channel: channel)
    }

    func url(_ path: String = "/") throws -> URL {
        try #require(URL(string: "http://127.0.0.1:\(port)\(path)"))
    }

    func stop() async throws {
        try await channel.close()
    }
}

final class RawHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let answer: [UInt8]
    private let thenClose: Bool
    private var seen = ByteBuffer()
    private var answered = false

    init(answer: [UInt8], thenClose: Bool) {
        self.answer = answer
        self.thenClose = thenClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var part = Self.unwrapInboundIn(data)
        seen.writeBuffer(&part)
        // The tests send requests without a body, so the head ends the request.
        guard !answered, String(buffer: seen).contains("\r\n\r\n") else { return }
        answered = true
        let channel = context.channel
        let written = context.writeAndFlush(Self.wrapOutboundOut(ByteBuffer(bytes: answer)))
        if thenClose {
            written.whenComplete { _ in channel.close(promise: nil) }
        }
    }
}

/// Runs `body` with a new server and client and shuts both down afterwards.
func withServer<T>(
    host: String = "127.0.0.1",
    _ body: (TestServer, LessonHTTPClient) async throws -> T
) async throws -> T {
    let server = try await TestServer.start(host: host)
    let client = LessonHTTPClient()
    do {
        let result = try await body(server, client)
        await client.shutdown()
        try await server.stop()
        return result
    } catch {
        await client.shutdown()
        try? await server.stop()
        throw error
    }
}

/// Runs `body` with a raw server and a new client and shuts both down afterwards.
func withRawServer(answer: String, _ body: (RawServer, LessonHTTPClient) async throws -> Void) async throws {
    let server = try await RawServer.start(answer: answer)
    let client = LessonHTTPClient()
    do {
        try await body(server, client)
    } catch {
        await client.shutdown()
        try? await server.stop()
        throw error
    }
    await client.shutdown()
    try await server.stop()
}

/// The case of an error, without its message.
enum ErrorKind {
    case invalidRequest, connectionFailed, tlsFailed, connectionLost, invalidResponse
    case invalidRedirect, tooManyRedirects, timedOut, cancelled, shutDown
}

extension LessonHTTPError {
    var kind: ErrorKind {
        switch self {
        case .invalidRequest: .invalidRequest
        case .connectionFailed: .connectionFailed
        case .tlsFailed: .tlsFailed
        case .connectionLost: .connectionLost
        case .invalidResponse: .invalidResponse
        case .invalidRedirect: .invalidRedirect
        case .tooManyRedirects: .tooManyRedirects
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        case .shutDown: .shutDown
        }
    }
}

/// Polls `condition` until it holds or `limit` passes.
func eventually(within limit: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

/// The first value of a field in a response's headers or trailers.
func value(_ name: String, in fields: [(name: String, value: String)]) -> String? {
    fields.first { $0.name.lowercased() == name.lowercased() }?.value
}

/// The bytes httpbin's /range/{n} returns: the alphabet, over and over.
func rangeBytes(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(ascii: "a") + UInt8($0 % 26) }
}

func sha256Hex(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

let gzipText = String(repeating: "The gopher reads every byte of the response. ", count: 8000)

/// gzip with the system zlib, the format Go's servers write.
func gzipped(_ data: Data) -> Data {
    var stream = z_stream()
    guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                        zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return Data() }
    defer { deflateEnd(&stream) }
    var output = Data()
    var buffer = [Bytef](repeating: 0, count: 64 << 10)
    data.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
        stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
        stream.avail_in = uInt(input.count)
        var status = Z_OK
        while status == Z_OK {
            status = buffer.withUnsafeMutableBufferPointer { out in
                stream.next_out = out.baseAddress
                stream.avail_out = uInt(out.count)
                return deflate(&stream, Z_FINISH)
            }
            output.append(contentsOf: buffer[0..<(buffer.count - Int(stream.avail_out))])
        }
    }
    return output
}
