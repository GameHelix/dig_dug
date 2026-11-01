import Foundation
import Network
import NIOCore
import NIOHTTP1
import Security
import Synchronization

/// A response as it came off the wire.
struct RawResponse: Sendable {
    var head: HTTPResponseHead
    var body: ByteBuffer
    var trailers: HTTPHeaders?
}

/// One request and its response on a connection of its own. A timeout or a cancelled task
/// ends it from outside the event loop: the result fails at once and the channel closes.
final class Exchange: Sendable {
    private enum State {
        case starting
        case open(any Channel)
        case ended
    }

    let promise: EventLoopPromise<RawResponse>
    private let state = Mutex<State>(.starting)

    init(promise: EventLoopPromise<RawResponse>) {
        self.promise = promise
    }

    /// Records the channel as it is created; false if the exchange has already ended.
    func attach(_ channel: any Channel) -> Bool {
        state.withLock { state in
            guard case .starting = state else { return false }
            state = .open(channel)
            return true
        }
    }

    /// Fails the exchange unless it already has a result, and closes the channel.
    func abort(_ error: LessonHTTPError) {
        let channel = end()
        promise.fail(error)
        channel?.close(promise: nil)
    }

    /// Ends the exchange and closes the channel if it is still open.
    func close() {
        end()?.close(promise: nil)
    }

    private func end() -> (any Channel)? {
        state.withLock { state in
            defer { state = .ended }
            if case .open(let channel) = state { return channel }
            return nil
        }
    }
}

/// Writes the request once the connection is up and collects the response, trailers included.
final class ExchangeHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let head: HTTPRequestHead
    private let body: ByteBuffer?
    private let promise: EventLoopPromise<RawResponse>
    private var response: HTTPResponseHead?
    private var received = ByteBuffer()

    private init(head: HTTPRequestHead, body: ByteBuffer?, promise: EventLoopPromise<RawResponse>) {
        self.head = head
        self.body = body
        self.promise = promise
    }

    /// Adds the HTTP/1.1 codec and the handler to a new channel. The encoder writes the head as
    /// given, so the framing headers are exactly the ones Go's rules chose.
    static func install(
        on channel: any Channel,
        head: HTTPRequestHead,
        body: ByteBuffer?,
        promise: EventLoopPromise<RawResponse>
    ) throws {
        var encoding = HTTPRequestEncoder.Configuration()
        encoding.automaticallySetFramingHeaders = false
        let pipeline = channel.pipeline.syncOperations
        try pipeline.addHandler(HTTPRequestEncoder(configuration: encoding))
        // The decoder sees the request go out, so it knows a response to HEAD has no body.
        try pipeline.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .dropBytes)))
        try pipeline.addHandler(ExchangeHandler(head: head, body: body, promise: promise))
    }

    func channelActive(context: ChannelHandlerContext) {
        context.write(Self.wrapOutboundOut(.head(head)), promise: nil)
        if let body {
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
        }
        context.writeAndFlush(Self.wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch Self.unwrapInboundIn(data) {
        case .head(let head):
            response = head
        case .body(var part):
            received.writeBuffer(&part)
        case .end(let trailers):
            if let response {
                promise.succeed(RawResponse(head: response, body: received, trailers: trailers))
            }
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise.fail(LessonHTTPError(exchanging: error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // Ignored when the response is already complete.
        promise.fail(LessonHTTPError.connectionLost("the server closed the connection before the response was complete"))
        context.fireChannelInactive()
    }
}

extension LessonHTTPError {
    /// A failure while connecting, including the TLS handshake.
    init(connecting error: any Error) {
        if let error = error as? LessonHTTPError {
            self = error
        } else if let error = error as? NWError {
            switch error {
            case .posix(let code): self = .connectionFailed(String(cString: strerror(code.rawValue)))
            case .dns(let code): self = .connectionFailed("the host name did not resolve (DNS error \(code))")
            case .tls(let status): self = .tlsFailed(Self.tlsMessage(status))
            default: self = .connectionFailed(error.debugDescription)
            }
        } else if let error = error as? ChannelError, case .connectTimeout = error {
            self = .timedOut
        } else if let error = error as? EventLoopError, case .shutdown = error {
            self = .shutDown
        } else {
            self = .connectionFailed(String(describing: error))
        }
    }

    /// A failure once the connection was up.
    init(exchanging error: any Error) {
        if let error = error as? LessonHTTPError {
            self = error
        } else if let error = error as? HTTPParserError {
            self = error == .invalidEOFState
                ? .connectionLost("the server closed the connection before the response was complete")
                : .invalidResponse("malformed HTTP/1.1 response (\(error))")
        } else if let error = error as? NWError {
            switch error {
            case .posix(let code): self = .connectionLost(String(cString: strerror(code.rawValue)))
            case .tls(let status): self = .tlsFailed(Self.tlsMessage(status))
            default: self = .connectionLost(error.debugDescription)
            }
        } else if let error = error as? EventLoopError, case .shutdown = error {
            self = .shutDown
        } else {
            self = .connectionLost(String(describing: error))
        }
    }

    private static func tlsMessage(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String?
        return "\(text ?? "error") (OSStatus \(status))"
    }
}
