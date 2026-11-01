import Foundation
import LessonHTTP

/// HTTP for command-line checks through the app's own HTTP/1.1 client on SwiftNIO: each
/// request goes out exactly as the step defines it, redirects follow Go's rules only when the
/// step allows them, and trailers are read. One client serves one check run.
public final class LessonHTTPTransport: HTTPSending {
    private let client = LessonHTTPClient()

    public init() {}

    public func send(_ request: CheckRequest) async throws -> CheckResponse {
        let lesson = LessonRequest(method: request.method, url: request.url,
                                   headers: request.headers.map { (name: $0.name, value: $0.value) },
                                   body: request.body,
                                   basicAuth: request.basicAuth.map { (user: $0.name, password: $0.value) },
                                   followRedirects: request.followRedirects, timeout: request.timeout)
        let response: LessonResponse
        do {
            response = try await client.send(lesson)
        } catch .cancelled {
            throw CancellationError()
        }
        return CheckResponse(statusCode: response.status,
                             headers: response.headers.map { NameValue($0.name, $0.value) },
                             trailers: response.trailers.map { NameValue($0.name, $0.value) },
                             body: response.body, url: response.url)
    }

    public func shutdown() async {
        await client.shutdown()
    }
}
