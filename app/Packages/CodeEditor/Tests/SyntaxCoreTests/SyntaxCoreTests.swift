import Foundation
import SyntaxCore
import Testing

/// Marks every occurrence of a word as a keyword.
private struct WordHighlighter: SyntaxHighlighting {
    let word: String

    func tokens(in text: String) -> [SyntaxToken] {
        let source = text as NSString
        var tokens: [SyntaxToken] = []
        var searchRange = NSRange(location: 0, length: source.length)
        while true {
            let found = source.range(of: word, range: searchRange)
            if found.location == NSNotFound { break }
            tokens.append(SyntaxToken(range: found, kind: .keyword))
            searchRange = NSRange(location: NSMaxRange(found), length: source.length - NSMaxRange(found))
        }
        return tokens
    }
}

@Suite struct SyntaxCoreTests {
    @Test func kindsCoverTheHighlightCategories() {
        #expect(SyntaxKind.allCases == [
            .keyword, .typeName, .builtin, .function, .string, .number, .comment, .operator, .punctuation, .plain,
        ])
        #expect(SyntaxKind(rawValue: "typeName") == .typeName)
    }

    @Test func tokensCompareByRangeAndKind() {
        let token = SyntaxToken(range: NSRange(location: 2, length: 3), kind: .string)
        #expect(token == SyntaxToken(range: NSRange(location: 2, length: 3), kind: .string))
        #expect(token != SyntaxToken(range: NSRange(location: 2, length: 3), kind: .comment))
        #expect(token != SyntaxToken(range: NSRange(location: 2, length: 4), kind: .string))
        #expect(Set([token, token]).count == 1)
    }

    @Test func rangesCountUTF16CodeUnits() {
        // The emoji takes two UTF-16 code units, so "func" starts at 3.
        let highlighter: any SyntaxHighlighting = WordHighlighter(word: "func")
        #expect(highlighter.tokens(in: "😀 func f() {}") == [SyntaxToken(range: NSRange(location: 3, length: 4), kind: .keyword)])
    }

    @Test func plainTextHighlighterLeavesTextPlain() {
        #expect(PlainTextHighlighter().tokens(in: "func main() {}").isEmpty)
    }

    @Test func highlightersCanRunOffTheMainThread() async {
        let highlighter: any SyntaxHighlighting = WordHighlighter(word: "go")
        let tokens = await Task.detached { highlighter.tokens(in: "go go") }.value
        #expect(tokens.map(\.range.location) == [0, 3])
    }
}
