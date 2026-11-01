import Foundation
import SyntaxCore

/// A lexer for Go source, following the lexical elements of the Go specification: line and
/// general comments, identifiers and keywords, integer, floating-point and imaginary literals
/// in every base, rune literals, and interpreted and raw string literals. It is forgiving: an
/// unterminated literal or comment runs to the end of its line (or of the text, for raw
/// strings and general comments), so highlighting keeps up while you type.
///
/// Tokens use SyntaxCore's kinds: predeclared types and declared type names are type names;
/// the predeclared constants (true, false, nil, iota) and called built-in functions are
/// builtins; rune literals are strings. Ranges are UTF-16, sorted and never overlapping.
public struct GoLexer: SyntaxHighlighting {
    public init() {}

    public func tokens(in text: String) -> [SyntaxToken] { GoLexer.tokens(text) }

    static let keywords: Set<String> = [
        "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go",
        "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
    ]
    static let types: Set<String> = [
        "any", "bool", "byte", "comparable", "complex64", "complex128", "error", "float32", "float64", "int", "int8", "int16",
        "int32", "int64", "rune", "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
    ]
    static let constants: Set<String> = ["true", "false", "iota", "nil"]
    static let builtins: Set<String> = [
        "append", "cap", "clear", "close", "complex", "copy", "delete", "imag", "len", "make", "max", "min", "new", "panic",
        "print", "println", "real", "recover",
    ]

    public static func tokens(_ source: String) -> [SyntaxToken] {
        let s = Array(source.utf16)
        let n = s.count
        var out: [SyntaxToken] = []
        var i = 0
        var previousWord = ""

        func at(_ k: Int) -> UInt16 { k < n ? s[k] : 0 }
        func isDecimal(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
        func isHex(_ c: UInt16) -> Bool { isDecimal(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66) }
        func isLetter(_ c: UInt16) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80 }

        while i < n {
            let c = s[i]
            let start = i
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
                continue
            case 0x2F where at(i + 1) == 0x2F: // line comment
                while i < n && s[i] != 0x0A { i += 1 }
                out.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            case 0x2F where at(i + 1) == 0x2A: // general comment
                i += 2
                while i < n && !(s[i] == 0x2A && at(i + 1) == 0x2F) { i += 1 }
                i = min(n, i + 2)
                out.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .comment))
                continue
            case 0x22, 0x27: // interpreted string, rune
                i += 1
                while i < n && s[i] != c && s[i] != 0x0A {
                    i += s[i] == 0x5C ? 2 : 1
                }
                if i < n && s[i] == c { i += 1 }
                i = min(i, n)
                out.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .string))
                previousWord = ""
                continue
            case 0x60: // raw string
                i += 1
                while i < n && s[i] != 0x60 { i += 1 }
                i = min(n, i + 1)
                out.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .string))
                previousWord = ""
                continue
            default:
                break
            }

            if isDecimal(c) || (c == 0x2E && isDecimal(at(i + 1))) {
                // int_lit, float_lit and imaginary_lit
                if c == 0x30 && (at(i + 1) | 0x20) == 0x78 { // 0x: hex int or hex float
                    i += 2
                    while i < n && (isHex(s[i]) || s[i] == 0x5F) { i += 1 }
                    if at(i) == 0x2E { i += 1; while i < n && (isHex(s[i]) || s[i] == 0x5F) { i += 1 } }
                    if (at(i) | 0x20) == 0x70 { // p exponent
                        i += 1
                        if at(i) == 0x2B || at(i) == 0x2D { i += 1 }
                        while i < n && (isDecimal(s[i]) || s[i] == 0x5F) { i += 1 }
                    }
                } else if c == 0x30 && ((at(i + 1) | 0x20) == 0x62 || (at(i + 1) | 0x20) == 0x6F) { // 0b, 0o
                    i += 2
                    while i < n && (isHex(s[i]) || s[i] == 0x5F) { i += 1 }
                } else {
                    while i < n && (isDecimal(s[i]) || s[i] == 0x5F) { i += 1 }
                    if at(i) == 0x2E { i += 1; while i < n && (isDecimal(s[i]) || s[i] == 0x5F) { i += 1 } }
                    if (at(i) | 0x20) == 0x65 && (isDecimal(at(i + 1)) || ((at(i + 1) == 0x2B || at(i + 1) == 0x2D) && isDecimal(at(i + 2)))) {
                        i += 2
                        while i < n && (isDecimal(s[i]) || s[i] == 0x5F) { i += 1 }
                    }
                }
                if at(i) == 0x69 { i += 1 } // imaginary
                out.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: .number))
                previousWord = ""
                continue
            }

            if isLetter(c) {
                while i < n && (isLetter(s[i]) || isDecimal(s[i])) { i += 1 }
                let word = String(decoding: s[start..<i], as: UTF16.self)
                var k = i
                while k < n && (s[k] == 0x20 || s[k] == 0x09) { k += 1 }
                let called = at(k) == 0x28 // "("
                let kind: SyntaxKind?
                if keywords.contains(word) {
                    kind = .keyword
                } else if types.contains(word) {
                    kind = .typeName
                } else if constants.contains(word) || (builtins.contains(word) && called) {
                    kind = .builtin
                } else if previousWord == "type" {
                    kind = .typeName
                } else if called || previousWord == "func" {
                    kind = .function
                } else {
                    kind = nil
                }
                if let kind { out.append(SyntaxToken(range: NSRange(location: start, length: i - start), kind: kind)) }
                previousWord = word
                continue
            }

            // Operators and punctuation are left plain, and end a "func name" or "type Name".
            previousWord = ""
            i += 1
        }
        return out
    }
}

/// Picks the highlighter for code: Go is highlighted, anything else stays plain.
public enum Highlighting {
    /// For a readme code block, by its language tag. Shell and output blocks stay plain, so
    /// `go mod init` does not light up like Go code.
    public static func forLanguage(_ language: String) -> any SyntaxHighlighting {
        ["go", "golang"].contains(language.lowercased()) ? GoLexer() : PlainTextHighlighter()
    }

    /// For a lesson file, by its name: .go files are Go; go.mod and data files stay plain.
    public static func forFile(_ name: String) -> any SyntaxHighlighting {
        name.lowercased().hasSuffix(".go") ? GoLexer() : PlainTextHighlighter()
    }
}
