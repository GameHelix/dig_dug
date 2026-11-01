import Foundation
import Testing

@testable import CodeEditor

private func toggled(_ string: String, _ marker: String = "// ") -> String? {
    let (text, selection) = marked(string)
    return LineComments.toggle(marker, in: text, selection: selection).map { applying($0, to: text) }
}

private func replaced(_ string: String, with newText: String) -> String? {
    let (text, selection) = marked(string)
    return TextEdit.replacing(text, with: newText as NSString, selection: selection).map { applying($0, to: text) }
}

@Suite struct LineCommentTests {
    @Test func commentsOutTheInsertionPointsLine() {
        #expect(toggled("x := |1") == "// x := |1")
        #expect(toggled("\tx := |1") == "\t// x := |1")
        // The insertion point stays with the character after it.
        #expect(toggled("\t|x") == "\t// |x")
        #expect(toggled("|\tx") == "|\t// x")
    }

    @Test func commentsOutSelectedLinesAtTheirSharedIndentation() {
        #expect(toggled("|\tif ok {\n\t\treturn\n\t}|") == "|\t// if ok {\n\t// \treturn\n\t// }|")
        #expect(toggled("|a\n\tb|") == "|// a\n// \tb|")
        #expect(toggled("|\ta\n    b|") == "|// \ta\n//     b|")
        // A selection that ends where a line starts leaves that line alone.
        #expect(toggled("|a\n|b") == "|// a\n|b")
    }

    @Test func uncommentsWhenEveryLineIsCommentedOut() {
        #expect(toggled("|\t// if ok {\n\t// \treturn\n\t// }|") == "|\tif ok {\n\t\treturn\n\t}|")
        #expect(toggled("// x := |1") == "x := |1")
        // Without a space after the marker, and with two: one space goes with it.
        #expect(toggled("//x|") == "x|")
        #expect(toggled("//  x|") == " x|")
        // An insertion point inside the marker moves to where it was.
        #expect(toggled("/|/ x") == "|x")
    }

    @Test func aLineNotCommentedOutCommentsThemAll() {
        #expect(toggled("|// a\nb|") == "|// // a\n// b|")
    }

    @Test func blankLinesStayAsTheyAre() {
        #expect(toggled("|a\n\n  \n\tb|") == "|// a\n\n  \n// \tb|")
        #expect(toggled("|// a\n   \n// b|") == "|a\n   \nb|")
        #expect(toggled("a\n|\nb") == nil)
        #expect(toggled("  |  ") == nil)
    }

    @Test func otherMarkers() {
        #expect(toggled("|echo hi\necho bye|", "# ") == "|# echo hi\n# echo bye|")
        #expect(toggled("  # key: |1", "# ") == "  key: |1")
        #expect(toggled("select |1", "-- ") == "-- select |1")
        #expect(toggled("-- select |1", "-- ") == "select |1")
    }
}

@Suite struct ReplacingTextTests {
    @Test func theSameTextIsNoEdit() {
        #expect(replaced("a|b", with: "ab") == nil)
        #expect(replaced("|", with: "") == nil)
    }

    @Test func onlyTheStretchThatDiffersIsReplaced() throws {
        let edit = try #require(TextEdit.replacing("func f() {\nx:=1\n}", with: "func f() {\n\tx := 1\n}", selection: NSRange(location: 0, length: 0)))
        #expect(edit.range == NSRange(location: 11, length: 3))
        #expect(edit.replacement == "\tx := ")
        let added = try #require(TextEdit.replacing("ab", with: "aXb", selection: NSRange(location: 0, length: 0)))
        #expect(added.range == NSRange(location: 1, length: 0) && added.replacement == "X")
    }

    @Test func theSelectionKeepsItsLinesAndColumns() {
        #expect(replaced("func f() {\nx:=|1\n}", with: "func f() {\n\tx := 1\n}") == "func f() {\n\tx |:= 1\n}")
        #expect(replaced("|ab\ncd|", with: "ab\n\tcd") == "|ab\n\tc|d")
        #expect(replaced("a\nb|", with: "c\nd") == "c\nd|")
    }

    @Test func aColumnOrLineThatIsGoneIsClamped() {
        #expect(replaced("aaaa|\nb", with: "a\nb") == "a|\nb")
        #expect(replaced("aaa|\r\nb", with: "a\r\nb") == "a|\r\nb")
        #expect(replaced("a\r\nbb|", with: "a\r\nb") == "a\r\nb|")
        #expect(replaced("a\nb\nc|", with: "a") == "a|")
        #expect(replaced("a\nb\n|", with: "x") == "|x")
    }

    @Test func neverInsideACharacter() {
        // Column 4 of the new line falls between the halves of the second emoji.
        #expect(replaced("😀😀|", with: "x😀😀") == "x😀|😀")
    }
}

@Suite struct LineSyntaxTests {
    @Test func commentMarkersByFileName() {
        for name in ["main.go", "main_test.go", "go.mod", "internal/auth/auth.go", "MAIN.GO"] {
            #expect(LineSyntax(fileName: name).commentMarker == "// ", "\(name)")
        }
        for name in ["run.sh", "setup.bash", "app.py", "config.yaml", "ci.yml", "pyproject.toml", "Makefile", "makefile"] {
            #expect(LineSyntax(fileName: name).commentMarker == "# ", "\(name)")
        }
        #expect(LineSyntax(fileName: "schema.sql").commentMarker == "-- ")
        for name in ["go.sum", "README.md", "data.json", "notes.txt", "mod", "Makefile.txt", ""] {
            #expect(LineSyntax(fileName: name).commentMarker == nil, "\(name)")
        }
        #expect(LineSyntax(fileName: "notes.txt") == .plainText)
    }

    @Test func indentationByFileName() {
        // Go and Makefiles always indent with tabs.
        #expect(LineSyntax(fileName: "main.go").indentUnit(in: "a\n    b") == "\t")
        #expect(LineSyntax(fileName: "Makefile").indentUnit(in: "a:\n  b") == "\t")
        // Others follow the file, else their kind's custom.
        #expect(LineSyntax(fileName: "run.sh").indentUnit(in: "if x; then\n    y\nfi") == "    ")
        #expect(LineSyntax(fileName: "run.sh").indentUnit(in: "x") == "\t")
        #expect(LineSyntax(fileName: "config.yaml").indentUnit(in: "a: 1") == "  ")
        #expect(LineSyntax(fileName: "app.py").indentUnit(in: "x = 1") == "    ")
        #expect(LineSyntax.plainText.indentUnit(in: "a\n  b") == "  ")
    }
}

@Suite struct CoveredLinesTests {
    @Test func linesASelectionCovers() {
        let text: NSString = "ab\ncd\r\nef\n"
        #expect(Lines.covered(by: NSRange(location: 1, length: 0), in: text) == [NSRange(location: 0, length: 2)])
        #expect(Lines.covered(by: NSRange(location: 1, length: 3), in: text) == [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)])
        // Ending where a line starts: that line is not covered.
        #expect(Lines.covered(by: NSRange(location: 0, length: 3), in: text) == [NSRange(location: 0, length: 2)])
        #expect(Lines.covered(by: NSRange(location: 0, length: 10), in: text).count == 3)
        // The empty line after the last line break.
        #expect(Lines.covered(by: NSRange(location: 10, length: 0), in: text) == [NSRange(location: 10, length: 0)])
    }

    @Test func aSelectionSpansLinesWhenItHoldsALineBreak() {
        let text: NSString = "ab\ncd"
        #expect(Lines.spanLines(NSRange(location: 0, length: 3), in: text))
        #expect(Lines.spanLines(NSRange(location: 1, length: 3), in: text))
        #expect(!Lines.spanLines(NSRange(location: 0, length: 2), in: text))
        #expect(!Lines.spanLines(NSRange(location: 2, length: 0), in: text))
    }
}
