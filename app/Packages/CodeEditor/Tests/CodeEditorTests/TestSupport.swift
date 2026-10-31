import Foundation
import SyntaxCore

/// A small highlighter for tests: a few keywords, numbers and line comments.
struct TestHighlighter: SyntaxHighlighting {
    private static let keywords: Set<String> = ["func", "if", "return", "for"]

    func tokens(in text: String) -> [SyntaxToken] {
        let units = Array(text.utf16)
        var tokens: [SyntaxToken] = []
        var index = 0
        func isLetter(_ unit: UInt16) -> Bool { (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A) }
        func isDigit(_ unit: UInt16) -> Bool { unit >= 0x30 && unit <= 0x39 }
        while index < units.count {
            let start = index
            if units[index] == 0x2F, index + 1 < units.count, units[index + 1] == 0x2F {
                while index < units.count, units[index] != 0x0A { index += 1 }
                tokens.append(SyntaxToken(range: NSRange(location: start, length: index - start), kind: .comment))
            } else if isDigit(units[index]) {
                while index < units.count, isDigit(units[index]) { index += 1 }
                tokens.append(SyntaxToken(range: NSRange(location: start, length: index - start), kind: .number))
            } else if isLetter(units[index]) {
                while index < units.count, isLetter(units[index]) { index += 1 }
                if Self.keywords.contains(String(decoding: units[start..<index], as: UTF16.self)) {
                    tokens.append(SyntaxToken(range: NSRange(location: start, length: index - start), kind: .keyword))
                }
            } else {
                index += 1
            }
        }
        return tokens
    }
}

/// A fixed-seed generator, so randomized tests repeat exactly.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
