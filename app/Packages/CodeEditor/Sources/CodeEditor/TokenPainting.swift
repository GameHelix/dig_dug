import AppKit
import SyntaxCore

enum TokenNormalizer {
    /// Sorts tokens, clips them to the text and to each other, and keeps only `kinds`, the
    /// ones that change how text looks.
    static func normalize(_ tokens: [SyntaxToken], length: Int, keeping kinds: Set<SyntaxKind>) -> [SyntaxToken] {
        var candidates = tokens.filter {
            kinds.contains($0.kind) && $0.range.location != NSNotFound && $0.range.length > 0
        }
        if !isSorted(candidates) {
            candidates.sort { $0.range.location < $1.range.location }
        }
        var result: [SyntaxToken] = []
        result.reserveCapacity(candidates.count)
        var end = 0
        for token in candidates {
            let lower = max(token.range.location, end)
            let upper = min(NSMaxRange(token.range), length)
            guard upper > lower else { continue }
            result.append(SyntaxToken(range: NSRange(location: lower, length: upper - lower), kind: token.kind))
            end = upper
        }
        return result
    }

    private static func isSorted(_ tokens: [SyntaxToken]) -> Bool {
        var previous = Int.min
        for token in tokens {
            if token.range.location < previous { return false }
            previous = token.range.location
        }
        return true
    }
}

/// The tokens a text storage shows, kept in step with edits, so that new tokens repaint only
/// the stretch that changed.
struct PaintedTokens {
    /// The painted tokens, in the current text's coordinates.
    private(set) var tokens: [SyntaxToken] = []
    /// Text edited since the last paint. Its attributes are whatever typing left there.
    private(set) var dirty: NSRange?

    mutating func reset() {
        tokens = []
        dirty = nil
    }

    /// Records a change of characters: `editedRange` holds the new text and `delta` is the
    /// change in length, as NSTextStorage reports them.
    mutating func noteEdit(in editedRange: NSRange, changeInLength delta: Int) {
        let old = NSRange(location: editedRange.location, length: editedRange.length - delta)
        var stale = editedRange
        var kept: [SyntaxToken] = []
        kept.reserveCapacity(tokens.count)
        for token in tokens {
            if NSMaxRange(token.range) <= old.location {
                kept.append(token)
            } else if token.range.location >= NSMaxRange(old) {
                kept.append(SyntaxToken(range: NSRange(location: token.range.location + delta, length: token.range.length), kind: token.kind))
            } else {
                stale = Self.union(stale, Self.map(token.range, replacing: old, delta: delta))
            }
        }
        tokens = kept
        dirty = dirty.map { Self.union(Self.map($0, replacing: old, delta: delta), stale) } ?? stale
    }

    /// The range to repaint so the storage shows `newTokens`, or nil when it already does.
    func repaintRange(for newTokens: [SyntaxToken], length: Int) -> NSRange? {
        var region = dirty.flatMap { $0.length > 0 ? $0 : nil }
        if newTokens != tokens {
            let shared = min(tokens.count, newTokens.count)
            var prefix = 0
            while prefix < shared, tokens[prefix] == newTokens[prefix] {
                prefix += 1
            }
            var suffix = 0
            while suffix < shared - prefix, tokens[tokens.count - 1 - suffix] == newTokens[newTokens.count - 1 - suffix] {
                suffix += 1
            }
            let lower = prefix > 0 ? NSMaxRange(tokens[prefix - 1].range) : 0
            let upper = suffix > 0 ? tokens[tokens.count - suffix].range.location : length
            let changed = NSRange(location: lower, length: max(0, upper - lower))
            region = region.map { Self.union($0, changed) } ?? changed
        }
        guard let region else { return nil }
        let lower = min(max(region.location, 0), length)
        let upper = min(NSMaxRange(region), length)
        return upper > lower ? NSRange(location: lower, length: upper - lower) : nil
    }

    /// Records that the storage now shows `newTokens` everywhere.
    mutating func commit(_ newTokens: [SyntaxToken]) {
        tokens = newTokens
        dirty = nil
    }

    /// Where a range of the old text lands after `old` was replaced and the length changed by
    /// `delta`. A range that overlaps the edit grows to cover the new text.
    static func map(_ range: NSRange, replacing old: NSRange, delta: Int) -> NSRange {
        if NSMaxRange(range) <= old.location { return range }
        if range.location >= NSMaxRange(old) {
            return NSRange(location: range.location + delta, length: range.length)
        }
        let lower = min(range.location, old.location)
        let upper = max(NSMaxRange(range), NSMaxRange(old)) + delta
        return NSRange(location: lower, length: max(0, upper - lower))
    }

    /// The union of two ranges, ignoring an empty one.
    private static func union(_ a: NSRange, _ b: NSRange) -> NSRange {
        if a.length == 0 { return b }
        if b.length == 0 { return a }
        return NSUnionRange(a, b)
    }
}

enum TokenPainter {
    /// Paints `range` of `storage` so it shows `tokens`, with plain text between them.
    /// `tokens` must be normalized. Call it between beginEditing and endEditing.
    static func paint(_ tokens: [SyntaxToken], in range: NSRange, of storage: NSTextStorage, style: EditorStyle) {
        let end = NSMaxRange(range)
        var position = range.location
        var index = firstIndex(in: tokens, endingAfter: range.location)
        while index < tokens.count, tokens[index].range.location < end {
            let token = tokens[index]
            let lower = max(token.range.location, position)
            let upper = min(NSMaxRange(token.range), end)
            if lower > position {
                storage.setAttributes(style.baseAttributes, range: NSRange(location: position, length: lower - position))
            }
            if upper > lower {
                storage.setAttributes(style.attributes(for: token.kind), range: NSRange(location: lower, length: upper - lower))
            }
            position = max(position, upper)
            index += 1
        }
        if end > position {
            storage.setAttributes(style.baseAttributes, range: NSRange(location: position, length: end - position))
        }
    }

    /// The index of the first token that ends after `location`.
    static func firstIndex(in tokens: [SyntaxToken], endingAfter location: Int) -> Int {
        var low = 0
        var high = tokens.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(tokens[middle].range) <= location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low
    }
}
