import Foundation

/// An edit the editor makes in place of a keystroke or for a command.
struct TextEdit: Equatable {
    /// The range to replace, in UTF-16 code units.
    var range: NSRange
    var replacement: String
    /// What is selected afterwards, or nil for an insertion point at the end of the replacement.
    var selection: NSRange?
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
                selection: NSRange(location: selection.location + (opened as NSString).length, length: 0)
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

    /// Takes one level off an indentation: a trailing tab, or as many trailing spaces as one
    /// level of `unit` is wide (four for a tab).
    static func outdented(_ indent: String, unit: String = "\t") -> String {
        if indent.hasSuffix("\t") {
            return String(indent.dropLast())
        }
        let width = !unit.isEmpty && unit.allSatisfy({ $0 == " " }) ? unit.count : EditorStyle.tabWidthInSpaces
        var result = Substring(indent)
        var removed = 0
        while removed < width, result.hasSuffix(" ") {
            result = result.dropLast()
            removed += 1
        }
        return String(result)
    }

    // MARK: Shifting lines

    /// Indents the lines a selection covers, or the insertion point's line, by `unit`. Empty
    /// lines among others stay empty. Nil when nothing changes.
    static func indent(_ text: NSString, selection: NSRange, unit: String) -> TextEdit? {
        let lines = Lines.covered(by: selection, in: text)
        let allEmpty = lines.allSatisfy { $0.length == 0 }
        var changes = TextChanges()
        for line in lines where line.length > 0 || allEmpty {
            changes.insert(unit, at: line.location)
        }
        return changes.edit(of: text, selection: selection)
    }

    /// Takes one level of indentation (`outdented`) off the lines a selection covers, or the
    /// insertion point's line. Nil when none of them is indented.
    static func outdent(_ text: NSString, selection: NSRange, unit: String) -> TextEdit? {
        var changes = TextChanges()
        for line in Lines.covered(by: selection, in: text) {
            let indent = Lines.leadingBlanks(of: line, in: text)
            guard indent.length > 0 else { continue }
            let kept = (outdented(text.substring(with: indent), unit: unit) as NSString).length
            changes.remove(NSRange(location: indent.location + kept, length: indent.length - kept))
        }
        return changes.edit(of: text, selection: selection)
    }

    /// One level of the indentation a text already uses: a tab, unless more of its indented
    /// lines start with a space than with a tab; then the spaces of the shallowest of those,
    /// two to eight. Nil when no line is indented.
    static func unit(in text: NSString) -> String? {
        let length = text.length
        guard length > 0 else { return nil }
        var characters = [unichar](repeating: 0, count: length)
        text.getCharacters(&characters, range: NSRange(location: 0, length: length))
        var tabbed = 0
        var spaced = 0
        var shallowest = Int.max
        var start = 0
        while start < length {
            var end = start
            while end < length, isBlank(characters[end]) {
                end += 1
            }
            if end > start, end < length, !CodeTextView.isParagraphBreak(characters[end]) {
                if characters[start] == 0x09 {
                    tabbed += 1
                } else {
                    spaced += 1
                    var spaces = 0
                    while characters[start + spaces] == 0x20 {
                        spaces += 1
                    }
                    shallowest = min(shallowest, spaces)
                }
            }
            while end < length, !CodeTextView.isParagraphBreak(characters[end]) {
                end += 1
            }
            start = end + 1
        }
        if tabbed == 0 && spaced == 0 { return nil }
        return tabbed >= spaced ? "\t" : String(repeating: " ", count: min(max(shallowest, 2), 8))
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

    /// A space or a tab.
    static func isBlank(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x09
    }
}
