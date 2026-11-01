import Foundation
import Testing

@testable import CodeEditor

@Suite struct LineIndexTests {
    @Test(arguments: [
        ("", [0]),
        ("a", [0]),
        ("a\n", [0, 2]),
        ("a\nb", [0, 2]),
        ("a\r\nb", [0, 3]),
        ("a\rb", [0, 2]),
        ("a\r", [0, 2]),
        ("a\u{2029}b", [0, 2]),
        ("a\u{2028}b", [0]),
        ("\n\n", [0, 1, 2]),
        ("\r\n\r\n", [0, 2, 4]),
        ("\n\r", [0, 1, 2]),
    ])
    func linesEndWhereParagraphsEnd(text: String, starts: [Int]) {
        let index = LineIndex(text as NSString)
        #expect(index.starts == starts)
        #expect(index.length == (text as NSString).length)
    }

    @Test func findsTheLineForAnOffset() {
        let index = LineIndex("ab\ncd\n\nef" as NSString)
        #expect(index.starts == [0, 3, 6, 7])
        #expect(index.count == 4)
        #expect(index.line(containing: 0) == 0)
        #expect(index.line(containing: 2) == 0)
        #expect(index.line(containing: 3) == 1)
        #expect(index.line(containing: 6) == 2)
        #expect(index.line(containing: 9) == 3)
    }

    @Test func findsTheLinesASelectionTouches() {
        let index = LineIndex("ab\ncd\n\nef" as NSString)
        #expect(index.lines(covering: NSRange(location: 1, length: 0)) == 0...0)
        #expect(index.lines(covering: NSRange(location: 1, length: 3)) == 0...1)
        #expect(index.lines(covering: NSRange(location: 0, length: 3)) == 0...0)
        #expect(index.lines(covering: NSRange(location: 4, length: 5)) == 1...3)
    }

    @Test func editsJoinAndSplitCRLF() {
        let text = NSMutableString(string: "a\rb")
        var index = LineIndex(text)
        text.insert("\n", at: 2)
        index.replaceCharacters(in: NSRange(location: 2, length: 0), newLength: 1, text: text)
        #expect(index.starts == [0, 3])
        text.deleteCharacters(in: NSRange(location: 2, length: 1))
        index.replaceCharacters(in: NSRange(location: 2, length: 1), newLength: 0, text: text)
        #expect(index.starts == [0, 2])
        text.insert("x", at: 2)
        index.replaceCharacters(in: NSRange(location: 2, length: 0), newLength: 1, text: text)
        #expect(index.starts == [0, 2])
        #expect(index.length == 4)
    }

    @Test func editsMatchReadingEverythingAgain() {
        var random = SeededGenerator(seed: 11)
        let pieces = ["a", "bc", "\n", "\r", "\r\n", "\u{2029}", "\t", "x\ny", "\n\r", "\u{2028}"]
        let text = NSMutableString(string: "func f() {\n\treturn 1\r\n}\r")
        var index = LineIndex(text)
        for step in 0..<2_000 {
            let location = Int.random(in: 0...text.length, using: &random)
            let removed = Int.random(in: 0...min(4, text.length - location), using: &random)
            let inserted = pieces[Int.random(in: 0..<pieces.count, using: &random)]
            text.replaceCharacters(in: NSRange(location: location, length: removed), with: inserted)
            index.replaceCharacters(
                in: NSRange(location: location, length: removed), newLength: (inserted as NSString).length, text: text
            )
            let reference = LineIndex(text)
            #expect(index.starts == reference.starts, "step \(step)")
            #expect(index.length == text.length)
            if index.starts != reference.starts { break }
        }
    }
}
