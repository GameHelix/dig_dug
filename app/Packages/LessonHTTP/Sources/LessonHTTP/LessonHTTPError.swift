import Foundation

/// Why a lesson request failed. The messages are written to be shown as they are.
public enum LessonHTTPError: Error, Sendable, Equatable {
    /// The request can't be sent as given: a bad method, URL or header.
    case invalidRequest(String)
    /// No connection could be made: refused, unreachable, or the name did not resolve.
    case connectionFailed(String)
    /// The TLS handshake failed.
    case tlsFailed(String)
    /// The connection broke or closed before the whole response arrived.
    case connectionLost(String)
    /// The response was not valid HTTP/1.1, or its gzip body could not be decoded.
    case invalidResponse(String)
    /// A redirect pointed somewhere the client can't follow.
    case invalidRedirect(String)
    /// The tenth redirect in a row, where Go's client stops.
    case tooManyRedirects
    /// The timeout passed before the response was complete.
    case timedOut
    /// The task sending the request was cancelled.
    case cancelled
    /// The client was shut down.
    case shutDown
}

extension LessonHTTPError: CustomStringConvertible, LocalizedError {
    public var description: String {
        switch self {
        case .invalidRequest(let message): "Invalid request: \(message)"
        case .connectionFailed(let message): "Could not connect: \(message)"
        case .tlsFailed(let message): "TLS handshake failed: \(message)"
        case .connectionLost(let message): "Connection lost: \(message)"
        case .invalidResponse(let message): "Invalid response: \(message)"
        case .invalidRedirect(let message): "Invalid redirect: \(message)"
        case .tooManyRedirects: "Stopped after 10 redirects"
        case .timedOut: "The request timed out"
        case .cancelled: "The request was cancelled"
        case .shutDown: "The HTTP client was shut down"
        }
    }

    public var errorDescription: String? { description }
}
