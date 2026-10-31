import Foundation
import SyntaxCore

/// A stand-in highlighter for the demo: a handful of words, numbers, double-quoted strings,
/// line comments and calls. The app uses its Go lexer instead.
struct DemoHighlighter: SyntaxHighlighting {
    private static let keywords: Set<String> = [
        "break", "case", "const", "continue", "default", "defer", "else", "for", "func", "go", "if",
        "import", "map", "package", "range", "return", "struct", "switch", "type", "var",
    ]
    private static let typeNames: Set<String> = ["bool", "byte", "error", "float64", "int", "rune", "string"]
    private static let builtins: Set<String> = ["append", "false", "len", "make", "new", "nil", "panic", "true"]

    func tokens(in text: String) -> [SyntaxToken] {
        let units = Array(text.utf16)
        var tokens: [SyntaxToken] = []
        var index = 0

        func add(_ start: Int, _ kind: SyntaxKind) {
            tokens.append(SyntaxToken(range: NSRange(location: start, length: index - start), kind: kind))
        }
        func isLetter(_ unit: UInt16) -> Bool {
            (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x5F
        }
        func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }

        while index < units.count {
            let start = index
            let unit = units[index]
            if unit == 0x2F, index + 1 < units.count, units[index + 1] == 0x2F {
                while index < units.count, units[index] != 0x0A { index += 1 }
                add(start, .comment)
            } else if unit == 0x22 {
                index += 1
                while index < units.count, units[index] != 0x22, units[index] != 0x0A {
                    index += units[index] == 0x5C ? 2 : 1
                }
                index = min(index + 1, units.count)
                add(start, .string)
            } else if isDigit(unit) {
                while index < units.count, isDigit(units[index]) || units[index] == 0x2E { index += 1 }
                add(start, .number)
            } else if isLetter(unit) {
                while index < units.count, isLetter(units[index]) || isDigit(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if Self.keywords.contains(word) {
                    add(start, .keyword)
                } else if Self.typeNames.contains(word) {
                    add(start, .typeName)
                } else if Self.builtins.contains(word) {
                    add(start, .builtin)
                } else if index < units.count, units[index] == 0x28 {
                    add(start, .function)
                }
            } else {
                index += 1
            }
        }
        return tokens
    }
}
