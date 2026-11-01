import AppKit
import SyntaxCore
import Testing

@testable import CodeEditor

private func token(_ location: Int, _ length: Int, _ kind: SyntaxKind) -> SyntaxToken {
    SyntaxToken(range: NSRange(location: location, length: length), kind: kind)
}

/// What each character looks like: its color object, and whether it is bold.
private func appearance(of storage: NSTextStorage) -> [String] {
    var result: [String] = []
    storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
        let color = (attributes[.foregroundColor] as? NSColor).map { "\(ObjectIdentifier($0))" } ?? "none"
        let bold = (attributes[.font] as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        let paragraph = attributes[.paragraphStyle] != nil
        result += Array(repeating: "\(color) \(bold) \(paragraph)", count: range.length)
    }
    return result
}

@Suite struct TokenPaintingTests {
    let style = EditorStyle(fontSize: 13)

    @Test func normalizingSortsClipsAndDropsPlainKinds() {
        let tokens = [
            token(10, 4, .number),
            token(0, 4, .keyword),
            token(2, 4, .string), // overlaps the keyword
            token(5, 1, .operator), // looks plain
            token(7, 0, .function), // empty
            token(NSNotFound, 2, .comment),
            token(12, 10, .comment), // overlaps the number and runs past the end
        ]
        #expect(TokenNormalizer.normalize(tokens, length: 16, keeping: style.styledKinds) == [
            token(0, 4, .keyword), token(4, 2, .string), token(10, 4, .number), token(14, 2, .comment),
        ])
    }

    @Test func paintingSetsEachKindsAttributes() {
        let storage = NSTextStorage(string: "func f() // hi", attributes: style.baseAttributes)
        let tokens = [token(0, 4, .keyword), token(5, 1, .function), token(9, 5, .comment)]
        TokenPainter.paint(tokens, in: NSRange(location: 0, length: storage.length), of: storage, style: style)

        func color(at index: Int) -> NSColor? { storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor }
        func isBold(at index: Int) -> Bool {
            (storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        }
        #expect(color(at: 0) === style.theme.color(for: .keyword))
        #expect(isBold(at: 0))
        #expect(color(at: 4) === style.theme.color(for: .plain))
        #expect(!isBold(at: 4))
        #expect(color(at: 5) === style.theme.color(for: .function))
        #expect(color(at: 7) === style.theme.color(for: .plain))
        #expect(color(at: 13) === style.theme.color(for: .comment))
        // Text storage shares equal attribute values between strings, so compare by value.
        for index in 0..<storage.length {
            #expect(storage.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle == style.paragraphStyle)
        }
    }

    @Test func paintingOnlyTouchesItsRange() {
        let storage = NSTextStorage(string: "func one\nfunc two", attributes: style.baseAttributes)
        let tokens = [token(0, 4, .keyword), token(9, 4, .keyword)]
        TokenPainter.paint(tokens, in: NSRange(location: 9, length: 8), of: storage, style: style)
        #expect(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor === style.theme.color(for: .plain))
        #expect(storage.attribute(.foregroundColor, at: 9, effectiveRange: nil) as? NSColor === style.theme.color(for: .keyword))
    }

    @Test func editsShiftTheTokensAfterThem() {
        var painted = PaintedTokens()
        painted.commit([token(0, 4, .keyword), token(10, 2, .number)])
        // Three characters typed at 5.
        painted.noteEdit(in: NSRange(location: 5, length: 3), changeInLength: 3)
        #expect(painted.tokens == [token(0, 4, .keyword), token(13, 2, .number)])
        #expect(painted.dirty == NSRange(location: 5, length: 3))
        // A character typed right after the keyword leaves it painted.
        painted.noteEdit(in: NSRange(location: 4, length: 1), changeInLength: 1)
        #expect(painted.tokens == [token(0, 4, .keyword), token(14, 2, .number)])
        #expect(painted.dirty == NSRange(location: 4, length: 5))
    }

    @Test func editsDropTheTokensTheyTouch() {
        var painted = PaintedTokens()
        painted.commit([token(0, 4, .keyword), token(6, 4, .keyword)])
        // One character deleted inside the second keyword.
        painted.noteEdit(in: NSRange(location: 7, length: 0), changeInLength: -1)
        #expect(painted.tokens == [token(0, 4, .keyword)])
        #expect(painted.dirty == NSRange(location: 6, length: 3))
    }

    @Test func repaintCoversOnlyWhatChanged() {
        var painted = PaintedTokens()
        let old = [token(0, 4, .keyword), token(10, 2, .number), token(20, 4, .keyword)]
        painted.commit(old)
        #expect(painted.repaintRange(for: old, length: 30) == nil)
        let changed = [token(0, 4, .keyword), token(10, 3, .number), token(20, 4, .keyword)]
        #expect(painted.repaintRange(for: changed, length: 30) == NSRange(location: 4, length: 16))
        let added = old + [token(26, 2, .number)]
        #expect(painted.repaintRange(for: added, length: 30) == NSRange(location: 24, length: 6))
        #expect(painted.repaintRange(for: [], length: 30) == NSRange(location: 0, length: 30))
    }

    @Test func mappingMovesRangesThroughAnEdit() {
        let old = NSRange(location: 10, length: 2)
        #expect(PaintedTokens.map(NSRange(location: 0, length: 5), replacing: old, delta: 3) == NSRange(location: 0, length: 5))
        #expect(PaintedTokens.map(NSRange(location: 12, length: 4), replacing: old, delta: 3) == NSRange(location: 15, length: 4))
        #expect(PaintedTokens.map(NSRange(location: 8, length: 3), replacing: old, delta: 3) == NSRange(location: 8, length: 7))
    }

    /// Typing, pasting, deleting and undo leave stale attributes in edited text; repainting just
    /// the changed stretch must still end up exactly like painting everything.
    @Test func repaintingChangesMatchesPaintingEverything() {
        var random = SeededGenerator(seed: 7)
        let highlighter = TestHighlighter()
        let pieces = ["func", "f", " ", "\n", "12", "// note", "return", "x", "if 3 {", "}", "\t", "/", "9"]
        let initial = "func main() {\n\tif x {\n\t\treturn 42 // answer\n\t}\n}\n"
        let storage = NSTextStorage(string: initial, attributes: style.baseAttributes)
        var painted = PaintedTokens()

        func freshTokens() -> [SyntaxToken] {
            TokenNormalizer.normalize(highlighter.tokens(in: storage.string), length: storage.length, keeping: style.styledKinds)
        }
        func highlight() {
            let tokens = freshTokens()
            if let range = painted.repaintRange(for: tokens, length: storage.length) {
                storage.beginEditing()
                TokenPainter.paint(tokens, in: range, of: storage, style: style)
                storage.endEditing()
            }
            painted.commit(tokens)
        }
        highlight()

        let staleKinds: [SyntaxKind] = [.plain, .keyword, .comment, .number]
        for step in 0..<400 {
            let length = storage.length
            let location = Int.random(in: 0...length, using: &random)
            let removed = Int.random(in: 0...min(6, length - location), using: &random)
            let inserted = pieces[Int.random(in: 0..<pieces.count, using: &random)]
            // Inserted text carries whatever attributes it had: typing's plain ones, or a
            // token's, as undo brings back.
            let kind = staleKinds[Int.random(in: 0..<staleKinds.count, using: &random)]
            storage.replaceCharacters(
                in: NSRange(location: location, length: removed),
                with: NSAttributedString(string: inserted, attributes: style.attributes(for: kind))
            )
            let insertedLength = (inserted as NSString).length
            painted.noteEdit(in: NSRange(location: location, length: insertedLength), changeInLength: insertedLength - removed)

            if step % 3 == 2 {
                highlight()
                let reference = NSTextStorage(string: storage.string, attributes: style.baseAttributes)
                TokenPainter.paint(freshTokens(), in: NSRange(location: 0, length: reference.length), of: reference, style: style)
                #expect(appearance(of: storage) == appearance(of: reference), "step \(step)")
            }
        }
    }
}
