import Foundation

/// An edit the editor makes in place of a keystroke.
struct TextEdit: Equatable {
    /// The range to replace, in UTF-16 code units.
    var range: NSRange
    var replacement: String
    /// Where the insertion point goes afterwards, or nil for the end of the replacement.
    var insertionPoint: Int?
}

/// Indentation the way gofmt lays it out: tabs, one level inside each bracket that ends a line.
enum Indentation {
    /// Return keeps the line's indentation up to the insertion point and adds a tab after an
    /// opening bracket. Between a bracket pair, the closing bracket moves to a line of its own.
    static func newline(in text: NSString, selection: NSRange) -> TextEdit {
        let lineStart = text.paragraphRange(for: NSRange(location: selection.location, length: 0)).location

        var indentEnd = lineStart
        while indentEnd < selection.location, isBlank(text.character(at: indentEnd)) {
            indentEnd += 1
        }
        let indent = text.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))

        var before = selection.location
        while before > lineStart, isBlank(text.character(at: before - 1)) {
            before -= 1
        }
        guard before > lineStart, let closer = closer(for: text.character(at: before - 1)) else {
            return TextEdit(range: selection, replacement: "\n" + indent)
        }

        var after = NSMaxRange(selection)
        while after < text.length, isBlank(text.character(at: after)) {
            after += 1
        }
        let opened = "\n" + indent + "\t"
        if after < text.length, text.character(at: after) == closer {
            return TextEdit(
                range: NSRange(location: selection.location, length: after - selection.location),
                replacement: opened + "\n" + indent,
                insertionPoint: selection.location + (opened as NSString).length
            )
        }
        return TextEdit(range: selection, replacement: opened)
    }

    /// A closing bracket typed on a line that holds only blanks before it takes one level off
    /// them. Returns nil when the bracket should go in as typed.
    static func closingBracket(_ typed: String, in text: NSString, selection: NSRange) -> TextEdit? {
        guard closingBrackets.contains(typed) else { return nil }
        let lineStart = text.paragraphRange(for: NSRange(location: selection.location, length: 0)).location
        guard selection.location > lineStart else { return nil }
        for offset in lineStart..<selection.location where !isBlank(text.character(at: offset)) {
            return nil
        }
        let indent = text.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
        return TextEdit(
            range: NSRange(location: lineStart, length: NSMaxRange(selection) - lineStart),
            replacement: outdented(indent) + typed
        )
    }

    /// Takes one level off an indentation: a trailing tab, or up to four trailing spaces.
    static func outdented(_ indent: String) -> String {
        if indent.hasSuffix("\t") {
            return String(indent.dropLast())
        }
        var result = Substring(indent)
        var removed = 0
        while removed < EditorStyle.tabWidthInSpaces, result.hasSuffix(" ") {
            result = result.dropLast()
            removed += 1
        }
        return String(result)
    }

    static let closingBrackets: Set<String> = ["}", ")", "]"]

    private static func closer(for character: unichar) -> unichar? {
        switch character {
        case 0x7B: 0x7D // { }
        case 0x28: 0x29 // ( )
        case 0x5B: 0x5D // [ ]
        default: nil
        }
    }

    private static func isBlank(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }
}
