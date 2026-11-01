import Foundation
import Testing

@testable import CodeEditor

private func newline(_ string: String) -> String {
    let (text, selection) = marked(string)
    return applying(Indentation.newline(in: text, selection: selection), to: text)
}

private func closing(_ bracket: String, _ string: String) -> String? {
    let (text, selection) = marked(string)
    return Indentation.closingBracket(bracket, in: text, selection: selection).map { applying($0, to: text) }
}

@Suite struct IndentationTests {
    @Test func returnKeepsTheLineIndentation() {
        #expect(newline("\tx := 1|") == "\tx := 1\n\t|")
        #expect(newline("\t\treturn nil|") == "\t\treturn nil\n\t\t|")
        #expect(newline("    spaces|") == "    spaces\n    |")
        #expect(newline("x := 1|") == "x := 1\n|")
        #expect(newline("|") == "\n|")
    }

    @Test func returnAddsATabAfterAnOpeningBrace() {
        #expect(newline("func main() {|") == "func main() {\n\t|")
        #expect(newline("\tif ok {|") == "\tif ok {\n\t\t|")
        #expect(newline("\tif ok {  |") == "\tif ok {  \n\t\t|")
        #expect(newline("import (|") == "import (\n\t|")
        #expect(newline("\tvalues := []int{|") == "\tvalues := []int{\n\t\t|")
        #expect(newline("\tlist := [|") == "\tlist := [\n\t\t|")
    }

    @Test func returnBetweenBracesPutsTheClosingBraceOnItsOwnLine() {
        #expect(newline("func main() {|}") == "func main() {\n\t|\n}")
        #expect(newline("\tif ok {| }") == "\tif ok {\n\t\t|\n\t}")
        #expect(newline("f(|)") == "f(\n\t|\n)")
        // A different closer stays where it is.
        #expect(newline("f{|)") == "f{\n\t|)")
    }

    @Test func returnInsideTheIndentationKeepsOnlyWhatIsBeforeIt() {
        #expect(newline("\t|\tx") == "\t\n\t|\tx")
    }

    @Test func returnReplacesTheSelection() {
        #expect(newline("\tx := |old|") == "\tx := \n\t|")
        #expect(newline("\tif ok {|old|}") == "\tif ok {\n\t\t|\n\t}")
    }

    @Test func returnReadsOnlyTheCurrentLine() {
        #expect(newline("func f() {\n\tx|") == "func f() {\n\tx\n\t|")
        #expect(newline("{\r\n\ty|") == "{\r\n\ty\n\t|")
        #expect(newline("\t{\n|") == "\t{\n\n|")
    }

    @Test func closingBraceOnABlankLineOutdentsOneLevel() {
        #expect(closing("}", "\t\t|") == "\t}|")
        #expect(closing("}", "func f() {\n\tx\n\t|") == "func f() {\n\tx\n}|")
        #expect(closing(")", "import (\n\t\"fmt\"\n\t|") == "import (\n\t\"fmt\"\n)|")
        #expect(closing("]", "\t\t|") == "\t]|")
        #expect(closing("}", "        |") == "    }|")
        #expect(closing("}", "\t  |") == "\t}|")
        #expect(closing("}", "\t\t|x|") == "\t}|")
    }

    @Test func closingBraceAfterCodeGoesInAsTyped() {
        #expect(closing("}", "\tx|") == nil)
        #expect(closing("}", "|") == nil)
        #expect(closing("}", "x\n|") == nil)
        #expect(closing("a", "\t\t|") == nil)
        #expect(closing("{", "\t\t|") == nil)
    }

    @Test func outdentingRemovesOneLevel() {
        #expect(Indentation.outdented("\t\t") == "\t")
        #expect(Indentation.outdented("\t") == "")
        #expect(Indentation.outdented("      ") == "  ")
        #expect(Indentation.outdented("\t  ") == "\t")
        #expect(Indentation.outdented("") == "")
        // One level of a two-space file is two spaces.
        #expect(Indentation.outdented("      ", unit: "  ") == "    ")
        #expect(Indentation.outdented("\t\t", unit: "  ") == "\t")
    }
}

private func indented(_ string: String, unit: String = "\t") -> String? {
    let (text, selection) = marked(string)
    return Indentation.indent(text, selection: selection, unit: unit).map { applying($0, to: text) }
}

private func outdented(_ string: String, unit: String = "\t") -> String? {
    let (text, selection) = marked(string)
    return Indentation.outdent(text, selection: selection, unit: unit).map { applying($0, to: text) }
}

@Suite struct ShiftingLinesTests {
    @Test func indentShiftsTheInsertionPointsLine() {
        #expect(indented("func f() {\nre|turn\n}") == "func f() {\n\tre|turn\n}")
        // The insertion point stays with the character after it.
        #expect(indented("|x") == "\t|x")
        #expect(indented("a\n|\nb") == "a\n\t|\nb")
        #expect(indented("|") == "\t|")
    }

    @Test func indentShiftsEverySelectedLineAndKeepsThemSelected() {
        #expect(indented("|a\nb|") == "|\ta\n\tb|")
        #expect(indented("a|a\nb|b") == "\ta|a\n\tb|b")
        // A selection that ends where a line starts leaves that line alone.
        #expect(indented("|a\nb\n|c") == "|\ta\n\tb\n|c")
        #expect(indented("|a\nb\n|") == "|\ta\n\tb\n|")
        // Empty lines among others stay empty; lines of blanks are lines.
        #expect(indented("|a\n\n  \nb|") == "|\ta\n\n\t  \n\tb|")
        #expect(indented("|a\r\nb|") == "|\ta\r\n\tb|")
        #expect(indented("|a\nb|", unit: "  ") == "|  a\n  b|")
    }

    @Test func outdentTakesOneLevelOffEachLine() {
        #expect(outdented("\t\tx|") == "\tx|")
        #expect(outdented("|\ta\n\t\tb|") == "|a\n\tb|")
        #expect(outdented("|a\n\tb|") == "|a\nb|")
        #expect(outdented("\t  x|") == "\tx|")
        #expect(outdented("      x|") == "  x|")
        #expect(outdented("      x|", unit: "  ") == "    x|")
        // An insertion point in the indentation that goes stays where the indentation ends.
        #expect(outdented("\t|\tx") == "\t|x")
        #expect(outdented("\t\t|") == "\t|")
    }

    @Test func outdentOfLinesWithoutIndentationChangesNothing() {
        #expect(outdented("|a\nb|") == nil)
        #expect(outdented("x|") == nil)
        #expect(outdented("|") == nil)
    }

    @Test func theIndentationAFileUses() {
        #expect(Indentation.unit(in: "func f() {\n\treturn\n}") == "\t")
        #expect(Indentation.unit(in: "a:\n  b: 1\n  c:\n    d: 2\n") == "  ")
        #expect(Indentation.unit(in: "def f():\n    return 1\n") == "    ")
        // The shallowest line counts, two to eight spaces; a tie goes to tabs.
        #expect(Indentation.unit(in: "/*\n * x\n */") == "  ")
        #expect(Indentation.unit(in: "\ta\n  b") == "\t")
        // Lines of nothing but blanks say nothing.
        #expect(Indentation.unit(in: "a\n    \n\tb") == "\t")
        #expect(Indentation.unit(in: "a\n    \nb") == nil)
        #expect(Indentation.unit(in: "x\r\ny") == nil)
        #expect(Indentation.unit(in: "") == nil)
    }
}
