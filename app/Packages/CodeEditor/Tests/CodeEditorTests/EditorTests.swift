import AppKit
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
