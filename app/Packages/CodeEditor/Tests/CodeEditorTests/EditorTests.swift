import AppKit
import SwiftUI
import SyntaxCore
import Testing

@testable import CodeEditor

@Suite struct EditorStyleTests {
    @Test func tabsAreFourSpacesWide() {
        let style = EditorStyle(fontSize: 13)
        let space = (" " as NSString).size(withAttributes: [.font: style.font]).width
        #expect(abs(style.paragraphStyle.defaultTabInterval - 4 * space) < 0.001)
        #expect(style.paragraphStyle.tabStops.isEmpty)
        #expect(style.font.fontName == NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontName)
        #expect(style.font.pointSize == 13)
    }

    @Test func everyKindKeepsTheBaseParagraphAndFontSize() {
        let style = EditorStyle(fontSize: 15)
        for kind in SyntaxKind.allCases {
            let attributes = style.attributes(for: kind)
            #expect(attributes[.paragraphStyle] as? NSParagraphStyle === style.paragraphStyle)
            #expect((attributes[.font] as? NSFont)?.pointSize == 15)
            #expect((attributes[.foregroundColor] as? NSColor) === style.theme.color(for: kind))
        }
    }
}

@Suite @MainActor struct DebouncerTests {
    @Test func firesOnceAfterTheLastSchedule() async throws {
        let debouncer = Debouncer(delay: .milliseconds(50))
        var fired: [Int] = []
        debouncer.schedule { fired.append(1) }
        debouncer.schedule { fired.append(2) }
        #expect(debouncer.isPending)
        try await Task.sleep(for: .milliseconds(400))
        #expect(fired == [2])
        #expect(!debouncer.isPending)
    }

    @Test func flushRunsThePendingActionNow() async throws {
        let debouncer = Debouncer(delay: .milliseconds(50))
        var fired = 0
        debouncer.schedule { fired += 1 }
        debouncer.flush()
        #expect(fired == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(fired == 1)
        debouncer.flush()
        #expect(fired == 1)
    }

    @Test func cancelDropsThePendingAction() async throws {
        let debouncer = Debouncer(delay: .milliseconds(50))
        var fired = 0
        debouncer.schedule { fired += 1 }
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(fired == 0)
    }
}

/// The text view's own behavior, without a window.
@Suite @MainActor struct CodeTextViewTests {
    private func makeTextView(_ text: String, selection: Int) -> CodeTextView {
        let textView = CodeTextView(usingTextLayoutManager: true)
        textView.configure()
        textView.string = text
        textView.setSelectedRange(NSRange(location: selection, length: 0))
        return textView
    }

    @Test func usesTextKit2WithCodeFriendlySettings() {
        let textView = makeTextView("x", selection: 0)
        #expect(textView.textLayoutManager != nil)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isContinuousSpellCheckingEnabled)
        #expect(!textView.isGrammarCheckingEnabled)
        #expect(!textView.smartInsertDeleteEnabled)
        #expect(!textView.isRichText)
        #expect(textView.allowsUndo)
        #expect(textView.usesFindBar)
        #expect(textView.isIncrementalSearchingEnabled)
    }

    @Test func returnIndentsAndSplitsBraces() {
        let textView = makeTextView("func main() {}", selection: 13)
        textView.insertNewline(nil)
        #expect(textView.string == "func main() {\n\t\n}")
        #expect(textView.selectedRange() == NSRange(location: 15, length: 0))
        #expect(textView.textLayoutManager != nil)
    }

    @Test func closingBraceOutdents() {
        let textView = makeTextView("if ok {\n\t\t", selection: 10)
        textView.insertText("}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.string == "if ok {\n\t}")
    }

    @Test func tabInsertsATab() {
        let textView = makeTextView("x", selection: 0)
        textView.insertTab(nil)
        #expect(textView.string == "\tx")
    }

    @Test func tabIndentsASelectionThatSpansLines() {
        let textView = makeTextView("a\nb", selection: 0)
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        textView.insertTab(nil)
        #expect(textView.string == "\ta\n\tb")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 5))
        // A whole line with its line break is a selection that spans lines too.
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        textView.insertTab(nil)
        #expect(textView.string == "\t\ta\n\tb")
        // Within one line, Tab replaces the selection as usual.
        textView.setSelectedRange(NSRange(location: 2, length: 1))
        textView.insertTab(nil)
        #expect(textView.string == "\t\t\t\n\tb")
    }

    @Test func shiftTabOutdentsTheLineOrTheSelectedLines() {
        let textView = makeTextView("\t\tx", selection: 3)
        textView.insertBacktab(nil)
        #expect(textView.string == "\tx")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
        textView.string = "\ta\n\tb"
        textView.setSelectedRange(NSRange(location: 0, length: 5))
        textView.insertBacktab(nil)
        #expect(textView.string == "a\nb")
        #expect(textView.selectedRange() == NSRange(location: 0, length: 3))
        textView.string = "\tx"
        textView.isEditable = false
        textView.insertBacktab(nil)
        #expect(textView.string == "\tx")
    }

    @Test func typedTextStartsPlain() {
        let textView = makeTextView("", selection: 0)
        textView.typingAttributes = [.foregroundColor: NSColor.red]
        #expect(textView.typingAttributes[.foregroundColor] as? NSColor === textView.style.theme.color(for: .plain))
        #expect(textView.typingAttributes[.paragraphStyle] as? NSParagraphStyle === textView.style.paragraphStyle)
    }

    @Test func readOnlyIgnoresTyping() {
        let textView = makeTextView("x", selection: 1)
        textView.isEditable = false
        textView.insertNewline(nil)
        #expect(textView.string == "x")
    }
}

/// The SwiftUI view's update path, driven through its coordinator in a window that is never shown.
@Suite @MainActor struct CodeEditorViewTests {
    private let code = (1...300).map { "line\($0) := \($0) // note" }.joined(separator: "\n")

    private func editor(showsLineNumbers: Bool) -> CodeEditorView {
        CodeEditorView(text: .constant(code), highlighter: TestHighlighter(), showsLineNumbers: showsLineNumbers)
    }

    @Test func lineNumbersToggleLiveAndKeepScrollAndSelection() throws {
        let coordinator = editor(showsLineNumbers: true).makeCoordinator()
        let scrollView = coordinator.scrollView
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = scrollView
        window.layoutIfNeeded()
        #expect(scrollView.rulersVisible)
        #expect(scrollView.verticalRulerView?.ruleThickness ?? 0 > 0)

        coordinator.textView.setSelectedRange(NSRange(location: 1_234, length: 5))
        let layoutManager = try #require(coordinator.textView.textLayoutManager)
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        window.layoutIfNeeded()
        let clipView = scrollView.contentView
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: 800))
        scrollView.reflectScrolledClipView(clipView)
        #expect(clipView.bounds.minY == 800)
        let widthWithNumbers = coordinator.textView.frame.width

        coordinator.update(editor(showsLineNumbers: false))
        window.layoutIfNeeded()
        #expect(!scrollView.rulersVisible)
        #expect(clipView.bounds.minY == 800)
        #expect(coordinator.textView.selectedRange() == NSRange(location: 1_234, length: 5))
        #expect(coordinator.textView.frame.width > widthWithNumbers)

        coordinator.update(editor(showsLineNumbers: true))
        window.layoutIfNeeded()
        #expect(scrollView.rulersVisible)
        #expect(clipView.bounds.minY == 800)
        #expect(coordinator.textView.selectedRange() == NSRange(location: 1_234, length: 5))
        #expect(coordinator.textView.frame.width == widthWithNumbers)
        #expect(coordinator.textView.textLayoutManager != nil)
    }
}

/// The code an editor writes back through its binding, and how often it did.
@MainActor private final class TextBox {
    var text: String
    var writes = 0

    init(_ text: String) {
        self.text = text
    }

    var binding: Binding<String> {
        Binding(get: { self.text }, set: { self.text = $0; self.writes += 1 })
    }
}

/// Commands from outside the editor, through its proxy, in a window that is never shown.
@Suite @MainActor struct CodeEditorProxyTests {
    private func editor(_ box: TextBox, fileName: String = "main.go", isEditable: Bool = true,
                        proxy: CodeEditorProxy) -> (CodeEditorView.Coordinator, NSWindow) {
        let coordinator = CodeEditorView(
            text: box.binding, highlighter: TestHighlighter(), lineSyntax: LineSyntax(fileName: fileName),
            isEditable: isEditable, proxy: proxy
        ).makeCoordinator()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true
        )
        window.contentView = coordinator.scrollView
        return (coordinator, window)
    }

    /// Ends the event, as the app's run loop does after each one: the undo manager closes the
    /// group it opened for the event's changes.
    private func endEvent() {
        RunLoop.current.run(mode: .default, before: Date())
    }

    @Test func eachCommandIsOneUndoStep() throws {
        let proxy = CodeEditorProxy()
        let box = TextBox("func f() {\nx := 1\n}")
        let (coordinator, window) = editor(box, proxy: proxy)
        let textView = coordinator.textView
        textView.setSelectedRange(NSRange(location: 11, length: 0))
        // No event ends between the commands: each closes its own undo step.
        #expect(proxy.indent())
        #expect(textView.string == "func f() {\n\tx := 1\n}" && box.text == textView.string)
        #expect(proxy.toggleComment())
        #expect(textView.string == "func f() {\n\t// x := 1\n}" && box.text == textView.string)
        #expect(textView.selectedRange() == NSRange(location: 15, length: 0))
        #expect(window.firstResponder === textView)

        let undo = try #require(textView.undoManager)
        #expect(undo.undoActionName == "Toggle Comment")
        undo.undo()
        #expect(textView.string == "func f() {\n\tx := 1\n}" && box.text == textView.string)
        #expect(undo.undoActionName == "Indent")
        undo.undo()
        #expect(textView.string == "func f() {\nx := 1\n}" && box.text == textView.string)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(textView.string == "func f() {\n\tx := 1\n}" && box.text == textView.string)
        #expect(proxy.outdent())
        #expect(textView.string == "func f() {\nx := 1\n}")
    }

    @Test func replacingTheCodeKeepsTheCaretAndUndoesInOneStep() throws {
        let proxy = CodeEditorProxy()
        let original = "package main\n\nfunc main() {\nx:=1\n_ = x\n}\n"
        let formatted = "package main\n\nfunc main() {\n\tx := 1\n\t_ = x\n}\n"
        let box = TextBox(original)
        let (coordinator, _) = editor(box, proxy: proxy)
        let textView = coordinator.textView
        // Line 5, "_ = x", column 2.
        textView.setSelectedRange(NSRange(location: (original as NSString).range(of: "_ = x").location + 2, length: 0))
        #expect(proxy.replaceText(with: formatted, actionName: "Format"))
        #expect(textView.string == formatted && box.text == formatted && proxy.text == formatted)
        let caret = (formatted as NSString).range(of: "\t_ = x").location + 2
        #expect(textView.selectedRange() == NSRange(location: caret, length: 0))
        // gofmt's output lands after the key press's event has ended; typing that follows it
        // in the next event is a step of its own.
        textView.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        endEvent()

        let undo = try #require(textView.undoManager)
        #expect(undo.undoActionName == "Typing")
        undo.undo()
        #expect(textView.string == formatted && box.text == formatted)
        #expect(undo.undoActionName == "Format")
        undo.undo()
        #expect(textView.string == original && box.text == original && proxy.text == original)
        #expect(!undo.canUndo)
    }

    /// TextKit 2 text views say nothing to their delegate when undo changes the text; the
    /// binding still gets the text back.
    @Test func undoingTypingWritesTheTextBack() throws {
        let proxy = CodeEditorProxy()
        let box = TextBox("x")
        let (coordinator, _) = editor(box, proxy: proxy)
        let textView = coordinator.textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(box.text == "xy")
        endEvent()
        let undo = try #require(textView.undoManager)
        undo.undo()
        #expect(textView.string == "x" && box.text == "x")
        undo.redo()
        #expect(textView.string == "xy" && box.text == "xy")
    }

    @Test func theSameCodeChangesNothing() {
        let proxy = CodeEditorProxy()
        let box = TextBox("package main\n")
        let (coordinator, _) = editor(box, proxy: proxy)
        #expect(!proxy.replaceText(with: "package main\n", actionName: "Format"))
        #expect(box.writes == 0)
        #expect(coordinator.textView.undoManager?.canUndo == false)
    }

    @Test func aReadOnlyEditorTakesNoCommands() {
        let proxy = CodeEditorProxy()
        let box = TextBox("\tx := 1")
        let (coordinator, _) = editor(box, isEditable: false, proxy: proxy)
        #expect(!proxy.indent() && !proxy.outdent() && !proxy.toggleComment())
        #expect(!proxy.replaceText(with: "x := 1", actionName: "Format"))
        #expect(coordinator.textView.string == "\tx := 1" && box.writes == 0)
    }

    @Test func toggleCommentNeedsAFileWithLineComments() {
        let proxy = CodeEditorProxy()
        let box = TextBox("x")
        _ = editor(box, fileName: "notes.txt", proxy: proxy)
        #expect(!proxy.toggleComment())
        #expect(box.text == "x" && box.writes == 0)
    }

    @Test func commandsShowHighlightedAtOnce() throws {
        let proxy = CodeEditorProxy()
        let box = TextBox("x := 1")
        let (coordinator, _) = editor(box, proxy: proxy)
        let storage = try #require(coordinator.textView.textStorage)
        #expect(proxy.toggleComment())
        // Painted as a comment already, not a moment later when highlighting runs.
        let color = storage.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor
        #expect(color === coordinator.textView.style.theme.color(for: .comment))
    }

    @Test func theProxyActsOnTheNewestEditor() {
        let proxy = CodeEditorProxy()
        #expect(proxy.text == nil && !proxy.indent())
        let first = CodeEditorView(text: .constant("first"), highlighter: TestHighlighter(), proxy: proxy).makeCoordinator()
        #expect(proxy.text == "first")
        let second = CodeEditorView(text: .constant("second"), highlighter: TestHighlighter(), proxy: proxy).makeCoordinator()
        #expect(proxy.text == "second")
        // The first editor going away leaves the second one attached.
        first.dismantle()
        #expect(proxy.text == "second")
        second.dismantle()
        #expect(proxy.text == nil)
    }
}
