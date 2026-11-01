import Foundation

/// One HTTP request exactly as a lesson step defines it.
public struct LessonRequest: Sendable {
    /// The method, sent as written. An empty method means GET, as in Go.
    public var method: String
    /// An http or https URL. A user and password written in it become basic auth, as in Go.
    public var url: URL
    /// The step's header fields, sent in this order. Host, Content-Length, Transfer-Encoding
    /// and Trailer come from the request itself, so values set here are ignored, as Go does.
    public var headers: [(name: String, value: String)]
    /// The body, sent byte for byte.
    public var body: Data?
    /// Sent in an Authorization header that replaces any the step sets, like Go's SetBasicAuth.
    public var basicAuth: (user: String, password: String)?
    /// Follow 301, 302, 303, 307 and 308 responses. When false, a 3xx response is returned.
    public var followRedirects: Bool
    /// The limit for the whole send: connecting, the exchange, and any redirects.
    public var timeout: Duration

    public init(
        method: String = "GET",
        url: URL,
        headers: [(name: String, value: String)] = [],
        body: Data? = nil,
        basicAuth: (user: String, password: String)? = nil,
        followRedirects: Bool = true,
        timeout: Duration = .seconds(30)
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.basicAuth = basicAuth
        self.followRedirects = followRedirects
        self.timeout = timeout
    }
}
