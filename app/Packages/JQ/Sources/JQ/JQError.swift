import Foundation

/// A jq failure, with jq's own message.
public enum JQError: Error, Sendable, Hashable {
    /// The program did not compile. The message is jq's diagnostics, one per line, as the jq
    /// command prints them.
    case compile(String)
    /// The program raised an error it did not catch, or stopped with `halt_error`.
    case runtime(String)
    /// The input is not JSON, or not JSON lines.
    case invalidJSON(String)

    /// jq's message.
    public var message: String {
        switch self {
        case .compile(let message), .runtime(let message), .invalidJSON(let message):
            message
        }
    }
}

extension JQError: LocalizedError {
    /// The error as the jq command reports it.
    public var errorDescription: String? {
        switch self {
        case .compile(let message): message
        case .runtime(let message): "jq: error: \(message)"
        case .invalidJSON(let message): "jq: parse error: \(message)"
        }
    }
}

/// How input text becomes the value a program runs on.
public enum JQInputMode: String, Sendable, Hashable, CaseIterable {
    /// The whole text is one JSON value.
    case json
    /// Each non-empty line is a JSON value; the values are collected into one array.
    case jsonl
}
