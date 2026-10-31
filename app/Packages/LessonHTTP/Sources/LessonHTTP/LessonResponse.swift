import Foundation

/// What came back for a lesson request.
public struct LessonResponse: Sendable {
    /// The status code, such as 200.
    public var status: Int
    /// Header fields as they arrived, in order. When the client asked for gzip on its own and
    /// decoded the body, Content-Encoding and Content-Length are removed, as Go does.
    public var headers: [(name: String, value: String)]
    /// The body, decoded from chunks and from gzip as above. Empty for HEAD.
    public var body: Data
    /// The trailer fields that followed a chunked body, in order.
    public var trailers: [(name: String, value: String)]
    /// The URL of the request that got this response, after any redirects.
    public var url: URL
    /// The time from the start of the send to the end of this response.
    public var duration: Duration

    public init(
        status: Int,
        headers: [(name: String, value: String)],
        body: Data,
        trailers: [(name: String, value: String)],
        url: URL,
        duration: Duration
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.trailers = trailers
        self.url = url
        self.duration = duration
    }
}
