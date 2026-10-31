import Foundation
import Testing

@testable import CodeEditor

/// Splits a "|"-marked string into text and selection: one "|" is the insertion point, two
/// mark a selection.
private func marked(_ string: String) -> (text: NSString, selection: NSRange) {
    let parts = string.components(separatedBy: "|")
    let start = (parts[0] as NSString).length
    let length = parts.count > 2 ? (parts[1] as NSString).length : 0
    return (parts.joined() as NSString, NSRange(location: start, length: length))
}

/// Applies an edit and marks where the insertion point lands.
private func applying(_ edit: TextEdit, to text: NSString) -> String {
    let result = text.replacingCharacters(in: edit.range, with: edit.replacement) as NSString
    let caret = edit.insertionPoint ?? edit.range.location + (edit.replacement as NSString).length
    return result.replacingCharacters(in: NSRange(location: caret, length: 0), with: "|")
}

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
    }
}
