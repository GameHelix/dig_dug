import Foundation
import Network
import NIOCore
import NIOHTTP1
import NIOTransportServices
import Synchronization

/// The HTTP/1.1 client for command-line lesson checks. It sends a step's request as written
/// and reports exactly what came back, trailers included, and it behaves like Go's net/http
/// client: no cookies, no cache, Go's default headers, Go's
/// redirect rules. Every request has a connection of its own and asks the server to close
/// it. TLS comes from Network.framework.
public final class LessonHTTPClient: Sendable {
    private let group = NIOTSEventLoopGroup(loopCount: 1, defaultQoS: .userInitiated)
    private let isShutDown = Mutex(false)

    public init() {}

    /// Sends the request and returns the last response, after any redirects it follows.
    public func send(_ request: LessonRequest) async throws(LessonHTTPError) -> LessonResponse {
        let started = ContinuousClock.now
        let deadline = NIODeadline.now() + TimeAmount(request.timeout)
        guard !isShutDown.withLock({ $0 }) else { throw .shutDown }

        let method = request.method.isEmpty ? "GET" : request.method
        guard isToken(method) else { throw .invalidRequest("invalid method \"\(method)\"") }
        // The fields as Go's Request.Header holds them once SetBasicAuth has run.
        var fields = try validated(request.headers)
        if let auth = request.basicAuth {
            fields.removeAll { sameName($0.name, "Authorization") }
            fields.append((name: "Authorization", value: basicCredentials(user: auth.user, password: auth.password)))
        }
        let first = try Target(request.url)

        var target = first
        var hopMethod = method
        var hopFields = fields
        var hopBody = request.body
        var keepsBody = true
        var dropsCredentials = false
        var sent = 0

        while true {
            if Task.isCancelled { throw .cancelled }
            var wireFields = hopFields
            if let credentials = target.credentials, (firstValue("Authorization", in: wireFields) ?? "").isEmpty {
                wireFields.append((name: "Authorization", value: basicCredentials(user: credentials.user, password: credentials.password)))
            }
            let (head, askedForGzip) = requestHead(method: hopMethod, target: target, fields: wireFields, body: hopBody)
            let raw = try await exchange(head: head, body: hopBody, target: target, deadline: deadline)
            sent += 1

            guard request.followRedirects,
                  let rule = redirectRule(status: Int(raw.head.status.code), method: hopMethod),
                  let location = raw.head.headers.first(name: "Location"), !location.isEmpty
            else {
                return try finish(raw, askedForGzip: askedForGzip, url: target.url, started: started)
            }
            guard let next = URL(string: location, relativeTo: target.url)?.absoluteURL else {
                throw .invalidRedirect("the Location \"\(location)\" is not a valid URL")
            }
            // Go's limit: the tenth redirect response in a row is an error.
            if sent >= 10 { throw .tooManyRedirects }
            let nextTarget: Target
            do {
                nextTarget = try Target(next)
            } catch .invalidRequest(let reason) {
                throw .invalidRedirect(reason)
            } catch {
                throw error
            }

            if !rule.keepsBody { keepsBody = false }
            // Once a redirect leaves the first host and its subdomains, credentials stay behind
            // for the rest of the chain.
            if !dropsCredentials, first.authority != nextTarget.authority,
               !isDomainOrSubdomain(nextTarget.hostname, of: first.hostname) {
                dropsCredentials = true
            }
            hopFields = dropsCredentials ? fields.filter { !credentialFields.contains($0.name.lowercased()) } : fields
            if (firstValue("Referer", in: hopFields) ?? "").isEmpty, let referer = referer(from: target.url, to: next) {
                hopFields.removeAll { sameName($0.name, "Referer") }
                hopFields.append((name: "Referer", value: referer))
            }
            hopMethod = rule.method
            hopBody = keepsBody ? request.body : nil
            target = nextTarget
        }
    }

    /// Shuts the client down; sends after this fail with `shutDown`. Calling it again does nothing.
    public func shutdown() async {
        let first = isShutDown.withLock { isShutDown in
            defer { isShutDown = true }
            return !isShutDown
        }
        guard first else { return }
        try? await group.shutdownGracefully()
    }

    /// Sends one request on a new connection and reads the whole response.
    private func exchange(head: HTTPRequestHead, body: Data?, target: Target, deadline: NIODeadline)
        async throws(LessonHTTPError) -> RawResponse
    {
        let remaining = deadline - NIODeadline.now()
        guard remaining > .zero else { throw .timedOut }
        let loop = group.next()
        let promise = loop.makePromise(of: RawResponse.self)
        let exchange = Exchange(promise: promise)
        let payload = body.flatMap { $0.isEmpty ? nil : ByteBuffer(bytes: $0) }

        var bootstrap = NIOTSConnectionBootstrap(group: loop)
            .connectTimeout(remaining)
            // Fail at once when the connection is refused instead of waiting for the network.
            .channelOption(NIOTSChannelOptions.waitForActivity, value: false)
            .channelInitializer { channel in
                guard exchange.attach(channel) else {
                    return channel.eventLoop.makeFailedFuture(LessonHTTPError.cancelled)
                }
                return channel.eventLoop.makeCompletedFuture {
                    try ExchangeHandler.install(on: channel, head: head, body: payload, promise: promise)
                }
            }
        if target.usesTLS {
            bootstrap = bootstrap.tlsOptions(Self.tlsOptions())
        }

        let timer = loop.scheduleTask(deadline: deadline) {
            exchange.abort(.timedOut)
        }
        bootstrap.connect(host: target.host, port: target.port).whenFailure { error in
            exchange.abort(LessonHTTPError(connecting: error))
        }
        defer {
            timer.cancel()
            exchange.close()
        }

        do {
            return try await withTaskCancellationHandler {
                try await promise.futureResult.get()
            } onCancel: {
                exchange.abort(.cancelled)
            }
        } catch {
            if isShutDown.withLock({ $0 }) { throw .shutDown }
            throw LessonHTTPError(exchanging: error)
        }
    }

    /// The response as the caller sees it, with the body decoded from gzip when the client
    /// asked for gzip itself, as Go's transport does.
    private func finish(_ raw: RawResponse, askedForGzip: Bool, url: URL, started: ContinuousClock.Instant)
        throws(LessonHTTPError) -> LessonResponse
    {
        var headers = raw.head.headers.map { (name: $0.name, value: $0.value) }
        var body = raw.body.withUnsafeReadableBytes { Data($0) }
        if askedForGzip, mayHaveBody(raw.head),
           raw.head.headers.first(name: "Content-Encoding")?.lowercased() == "gzip" {
            body = try Gzip.decode(body)
            headers.removeAll { sameName($0.name, "Content-Encoding") || sameName($0.name, "Content-Length") }
        }
        let trailers = raw.trailers.map { $0.map { (name: $0.name, value: $0.value) } } ?? []
        return LessonResponse(
            status: Int(raw.head.status.code),
            headers: headers,
            body: body,
            trailers: trailers,
            url: url,
            duration: ContinuousClock.now - started
        )
    }

    /// TLS from Network.framework with the system's trust, offering only HTTP/1.1 and at
    /// least TLS 1.2, like Go's client.
    private static func tlsOptions() -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        sec_protocol_options_add_tls_application_protocol(options.securityProtocolOptions, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        return options
    }
}
