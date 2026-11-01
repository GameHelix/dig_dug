import Foundation
import SyntaxCore

@testable import CodeEditor

/// Splits a "|"-marked string into text and selection: one "|" is the insertion point, two
/// mark a selection.
func marked(_ string: String) -> (text: NSString, selection: NSRange) {
    let parts = string.components(separatedBy: "|")
    let start = (parts[0] as NSString).length
    let length = parts.count > 2 ? (parts[1] as NSString).length : 0
    return (parts.joined() as NSString, NSRange(location: start, length: length))
}

/// Applies an edit and marks what is selected afterwards, the way `marked` reads it.
func applying(_ edit: TextEdit, to text: NSString) -> String {
    let result = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
    let selection = edit.selection ?? NSRange(location: edit.range.location + (edit.replacement as NSString).length, length: 0)
    return marking(selection, in: result)
}

/// The text with "|" at the insertion point, or around the selection.
func marking(_ selection: NSRange, in text: NSString) -> String {
    let end = selection.length > 0 ? text.replacingCharacters(in: NSRange(location: NSMaxRange(selection), length: 0), with: "|") : text as String
    return (end as NSString).replacingCharacters(in: NSRange(location: selection.location, length: 0), with: "|")
}

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
