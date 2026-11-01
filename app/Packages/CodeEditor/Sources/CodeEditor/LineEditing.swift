import Foundation

/// Lines of a text as the ranges of their characters, line breaks left out.
enum Lines {
    /// The lines a selection covers, or the insertion point's line. A selection that ends
    /// where a line starts does not cover that line.
    static func covered(by selection: NSRange, in text: NSString) -> [NSRange] {
        let last = selection.length > 0 ? NSMaxRange(selection) - 1 : selection.location
        var lines: [NSRange] = []
        var start = text.paragraphRange(for: NSRange(location: selection.location, length: 0)).location
        repeat {
            var end = 0
            var contentsEnd = 0
            text.getParagraphStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
            lines.append(NSRange(location: start, length: contentsEnd - start))
            start = end
        } while start <= last && start < text.length
        return lines
    }

    /// Whether a selection holds a line break, so it reaches into another line.
    static func spanLines(_ selection: NSRange, in text: NSString) -> Bool {
        selection.length > 0 && text.rangeOfCharacter(from: .newlines, range: selection).location != NSNotFound
    }

    /// The spaces and tabs a line starts with.
    static func leadingBlanks(of line: NSRange, in text: NSString) -> NSRange {
        var end = line.location
        while end < NSMaxRange(line), Indentation.isBlank(text.character(at: end)) {
            end += 1
        }
        return NSRange(location: line.location, length: end - line.location)
    }

    /// Whether a line holds nothing but spaces and tabs.
    static func isBlank(_ line: NSRange, in text: NSString) -> Bool {
        leadingBlanks(of: line, in: text).length == line.length
    }
}

/// Changes at places in a text, made as one edit. They come in order and none overlaps
/// another; each inserts text or removes some.
struct TextChanges {
    private var changes: [(range: NSRange, replacement: String)] = []

    mutating func insert(_ string: String, at location: Int) {
        changes.append((NSRange(location: location, length: 0), string))
    }

    mutating func remove(_ range: NSRange) {
        guard range.length > 0 else { return }
        changes.append((range, ""))
    }

    /// One edit of the stretch from the first change to the last. The selection moves with
    /// the text around it: an insertion point follows the character after it, and a
    /// selection takes in text inserted where it starts. Nil when there is no change.
    func edit(of text: NSString, selection: NSRange) -> TextEdit? {
        guard let first = changes.first, let last = changes.last else { return nil }
        let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var replacement = ""
        var position = range.location
        for change in changes {
            replacement += text.substring(with: NSRange(location: position, length: change.range.location - position))
            replacement += change.replacement
            position = NSMaxRange(change.range)
        }
        let moved: NSRange
        if selection.length == 0 {
            moved = NSRange(location: map(selection.location, keepingBefore: false), length: 0)
        } else {
            let start = map(selection.location, keepingBefore: true)
            let end = map(NSMaxRange(selection), keepingBefore: true)
            moved = NSRange(location: start, length: max(0, end - start))
        }
        return TextEdit(range: range, replacement: replacement, selection: moved)
    }

    /// Where a place in the text lands after the changes. At an insertion, `keepingBefore`
    /// keeps it in front of the inserted text; otherwise it moves past it. A place inside
    /// removed text moves to where the removal was.
    private func map(_ location: Int, keepingBefore: Bool) -> Int {
        var shift = 0
        for change in changes {
            let start = change.range.location
            let end = NSMaxRange(change.range)
            let inserted = (change.replacement as NSString).length
            if location < start || (location == start && (keepingBefore || end > start)) { break }
            if location < end { return start + shift + (keepingBefore ? 0 : inserted) }
            shift += inserted - change.range.length
        }
        return location + shift
    }
}

/// Line comments, put in front of lines and taken off again.
enum LineComments {
    /// Comments out the lines a selection covers, or the insertion point's line: `marker`,
    /// such as "// ", goes in at the indentation they share. When every one of them that is
    /// not blank already starts with the marker after its indentation, the marker comes off
    /// them instead, with the space after it. Blank lines stay as they are. Nil when every
    /// line is blank.
    static func toggle(_ marker: String, in text: NSString, selection: NSRange) -> TextEdit? {
        let bare = marker.trimmingCharacters(in: .whitespaces) as NSString
        let lines = Lines.covered(by: selection, in: text).filter { !Lines.isBlank($0, in: text) }
        guard bare.length > 0, !lines.isEmpty else { return nil }
        let indents = lines.map { Lines.leadingBlanks(of: $0, in: text) }
        let commented = zip(lines, indents).allSatisfy { line, indent in
            let code = NSRange(location: NSMaxRange(indent), length: NSMaxRange(line) - NSMaxRange(indent))
            return code.length >= bare.length && text.substring(with: NSRange(location: code.location, length: bare.length)) == bare as String
        }
        var changes = TextChanges()
        if commented {
            for (line, indent) in zip(lines, indents) {
                let start = NSMaxRange(indent)
                var length = bare.length
                if start + length < NSMaxRange(line), text.character(at: start + length) == 0x20 {
                    length += 1
                }
                changes.remove(NSRange(location: start, length: length))
            }
        } else {
            var shared = indents.map(\.length).min() ?? 0
            for indent in indents.dropFirst() {
                var same = 0
                while same < shared, text.character(at: indent.location + same) == text.character(at: indents[0].location + same) {
                    same += 1
                }
                shared = same
            }
            for line in lines {
                changes.insert(marker, at: line.location + shared)
            }
        }
        return changes.edit(of: text, selection: selection)
    }
}

extension TextEdit {
    /// The edit that turns `text` into `newText`: the stretch between what the two share at
    /// the start and at the end. Each end of the selection keeps its line and column where
    /// `newText` has them: a column past the line's end goes to the end, a line past the last
    /// one to the last. Nil when the texts are the same.
    static func replacing(_ text: NSString, with newText: NSString, selection: NSRange) -> TextEdit? {
        guard !text.isEqual(to: newText as String) else { return nil }
        let oldLength = text.length
        let newLength = newText.length
        let shared = min(oldLength, newLength)
        var prefix = 0
        while prefix < shared, text.character(at: prefix) == newText.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < shared - prefix, text.character(at: oldLength - 1 - suffix) == newText.character(at: newLength - 1 - suffix) {
            suffix += 1
        }
        let oldLines = LineIndex(text)
        let newLines = LineIndex(newText)
        func moved(_ location: Int) -> Int {
            let line = oldLines.line(containing: location)
            let column = location - oldLines.starts[line]
            let target = min(line, newLines.count - 1)
            var result = min(newLines.starts[target] + column, newLines.contentEnd(of: target, in: newText))
            if result < newLength {
                // Never between the halves of a surrogate pair or inside a composed character.
                result = newText.rangeOfComposedCharacterSequence(at: result).location
            }
            return result
        }
        let start = moved(selection.location)
        let end = selection.length > 0 ? max(start, moved(NSMaxRange(selection))) : start
        return TextEdit(
            range: NSRange(location: prefix, length: oldLength - prefix - suffix),
            replacement: newText.substring(with: NSRange(location: prefix, length: newLength - prefix - suffix)),
            selection: NSRange(location: start, length: end - start)
        )
    }
}
