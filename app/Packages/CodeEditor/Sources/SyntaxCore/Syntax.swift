import Foundation

/// What a highlighted stretch of source text is.
public enum SyntaxKind: String, Sendable, Hashable, CaseIterable {
    case keyword
    case typeName
    /// A predeclared identifier, such as a built-in function or constant.
    case builtin
    case function
    case string
    case number
    case comment
    case `operator`
    case punctuation
    case plain
}

/// A highlighted range of source text. The range counts UTF-16 code units, so it maps straight
/// onto NSString and NSTextStorage.
public struct SyntaxToken: Hashable, Sendable {
    public var range: NSRange
    public var kind: SyntaxKind

    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// Turns source text into highlighted ranges.
///
/// Tokens should be sorted by location and must not overlap; text no token covers is plain.
/// The editor calls `tokens(in:)` off the main thread.
public protocol SyntaxHighlighting: Sendable {
    func tokens(in text: String) -> [SyntaxToken]
}

/// Leaves all text plain, for files that have no highlighter.
public struct PlainTextHighlighter: SyntaxHighlighting {
    public init() {}

    public func tokens(in text: String) -> [SyntaxToken] { [] }
}
