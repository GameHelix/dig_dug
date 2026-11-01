import AppKit
import SwiftUI
import SyntaxCore

/// A code editor: an NSTextView on TextKit 2 with SF Mono, line numbers, a current-line
/// highlight, the find bar, undo, gofmt-style indentation and highlighting in Xcode's colors.
/// Tab and Shift-Tab indent and outdent selected lines, and a `CodeEditorProxy` lets menu
/// commands indent, outdent, comment out and replace the code.
public struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let highlighter: any SyntaxHighlighting
    let lineSyntax: LineSyntax
    let fontSize: CGFloat
    let isEditable: Bool
    let showsLineNumbers: Bool
    let accessibilityLabel: String
    let proxy: CodeEditorProxy?
    let onIdle: @MainActor (String) -> Void
    let onOptionClick: (@MainActor (Int) -> Void)?

    /// - Parameters:
    ///   - text: The code. The editor writes every edit back at once.
    ///   - highlighter: Turns the code into tokens, off the main thread. Passing a highlighter
    ///     of another type highlights the code again.
    ///   - lineSyntax: How the code's lines are commented out and indented, by its file's kind.
    ///   - fontSize: The size of SF Mono, in points.
    ///   - isEditable: Whether the code can be edited. Read-only code can still be selected,
    ///     copied and searched.
    ///   - showsLineNumbers: Whether the gutter with line numbers shows.
    ///   - accessibilityLabel: What VoiceOver calls the editor.
    ///   - proxy: Edits this editor's code for commands from outside it.
    ///   - onIdle: Called with the code one second after typing stops. A pending call is made
    ///     at once when the text is replaced from outside or the editor goes away.
    ///   - onOptionClick: Called with the UTF-16 offset of the word character clicked with
    ///     Option held, for Quick Help. Without it, or off a word, Option-click selects as usual.
    public init(
        text: Binding<String>,
        highlighter: any SyntaxHighlighting,
        lineSyntax: LineSyntax = .plainText,
        fontSize: CGFloat = 13,
        isEditable: Bool = true,
        showsLineNumbers: Bool = true,
        accessibilityLabel: String = "Code editor",
        proxy: CodeEditorProxy? = nil,
        onIdle: @escaping @MainActor (String) -> Void = { _ in },
        onOptionClick: (@MainActor (Int) -> Void)? = nil
    ) {
        _text = text
        self.highlighter = highlighter
        self.lineSyntax = lineSyntax
        self.fontSize = fontSize
        self.isEditable = isEditable
        self.showsLineNumbers = showsLineNumbers
        self.accessibilityLabel = accessibilityLabel
        self.proxy = proxy
        self.onIdle = onIdle
        self.onOptionClick = onOptionClick
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }

    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.dismantle()
    }
}

extension CodeEditorView {
    /// Owns the text view and keeps it, the binding and the highlighting in step.
    @MainActor
    public final class Coordinator: NSObject, NSTextViewDelegate {
        /// How long highlighting waits after an edit.
        static let highlightDelay: Duration = .milliseconds(100)
        /// New text up to this many UTF-16 code units is highlighted before it first shows.
        static let synchronousHighlightLimit = 100_000

        let scrollView = CodeScrollView()
        let textView = CodeTextView(usingTextLayoutManager: true)
        let lineNumbers: LineNumberRulerView
        private var configuration: CodeEditorView
        private var style: EditorStyle
        private var highlighter: any SyntaxHighlighting
        private let undoManager = UndoManager()
        private var painted = PaintedTokens()
        /// The code as the text view holds it.
        private(set) var text = ""
        private var generation = 0
        private var isReplacingText = false
        private var highlightTask: Task<Void, Never>?
        private let idle = Debouncer(delay: .seconds(1))

        init(_ configuration: CodeEditorView) {
            self.configuration = configuration
            style = EditorStyle(fontSize: configuration.fontSize)
            highlighter = configuration.highlighter
            lineNumbers = LineNumberRulerView(textView: textView, scrollView: scrollView)
            super.init()

            textView.configure()
            textView.style = style
            textView.lineSyntax = configuration.lineSyntax
            textView.isEditable = configuration.isEditable
            textView.setAccessibilityLabel(configuration.accessibilityLabel)
            textView.delegate = self
            textView.textStorage?.delegate = self
            textView.didApplyEdit = { [weak self] in
                self?.highlightNow()
            }
            textView.onOptionClick = optionClickHandler(for: configuration)

            scrollView.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
            textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.borderType = .noBorder
            scrollView.backgroundColor = style.theme.background
            scrollView.verticalRulerView = lineNumbers
            scrollView.hasVerticalRuler = true
            scrollView.rulersVisible = configuration.showsLineNumbers
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(visibleAreaDidChange(_:)),
                name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
            // A text view on TextKit 2 tells its delegate nothing when undo or redo changes the
            // text, so the coordinator takes the text in itself then.
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                NotificationCenter.default.addObserver(self, selector: #selector(undoDidChangeText(_:)), name: name, object: undoManager)
            }

            replaceText(with: configuration.text)
            configuration.proxy?.attach(self)
        }

        func update(_ newConfiguration: CodeEditorView) {
            let textChanged = newConfiguration.text != text
            if textChanged {
                // A pending idle call belongs to the text being replaced.
                flushIdle()
            }
            if newConfiguration.proxy !== configuration.proxy {
                configuration.proxy?.detach(self)
                newConfiguration.proxy?.attach(self)
            }
            configuration = newConfiguration

            if (textView.onOptionClick == nil) != (newConfiguration.onOptionClick == nil) {
                textView.onOptionClick = optionClickHandler(for: newConfiguration)
            }
            if textView.isEditable != newConfiguration.isEditable {
                textView.isEditable = newConfiguration.isEditable
            }
            if textView.lineSyntax != newConfiguration.lineSyntax {
                textView.lineSyntax = newConfiguration.lineSyntax
            }
            if scrollView.rulersVisible != newConfiguration.showsLineNumbers {
                scrollView.rulersVisible = newConfiguration.showsLineNumbers
            }
            if textView.accessibilityLabel() != newConfiguration.accessibilityLabel {
                textView.setAccessibilityLabel(newConfiguration.accessibilityLabel)
            }
            let fontChanged = newConfiguration.fontSize != style.fontSize
            if fontChanged {
                style = EditorStyle(fontSize: newConfiguration.fontSize)
                textView.style = style
                lineNumbers.refresh()
            }
            let highlighterChanged = type(of: newConfiguration.highlighter) != type(of: highlighter)
            highlighter = newConfiguration.highlighter

            if textChanged {
                replaceText(with: newConfiguration.text)
                return
            }
            if fontChanged {
                repaintAll()
            }
            if highlighterChanged {
                painted.reset()
                scheduleHighlight(after: .zero)
            }
        }

        /// Hands an Option-click to the handler of the configuration current at the click; nil
        /// leaves Option-click to the text view.
        private func optionClickHandler(for configuration: CodeEditorView) -> ((Int) -> Void)? {
            guard configuration.onOptionClick != nil else { return nil }
            return { [weak self] offset in self?.configuration.onOptionClick?(offset) }
        }

        func dismantle() {
            highlightTask?.cancel()
            flushIdle()
            configuration.proxy?.detach(self)
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: Text

        /// Shows new text from outside: highlighted, at the top, with nothing to undo.
        private func replaceText(with newText: String) {
            guard let storage = textView.textStorage else { return }
            highlightTask?.cancel()
            if textView.hasMarkedText() {
                textView.unmarkText()
            }
            generation += 1
            painted.reset()

            let length = (newText as NSString).length
            let tokens = length <= Self.synchronousHighlightLimit ? normalizedTokens(in: newText, length: length) : nil
            isReplacingText = true
            storage.beginEditing()
            storage.setAttributedString(NSAttributedString(string: newText, attributes: style.baseAttributes))
            if let tokens {
                TokenPainter.paint(tokens, in: NSRange(location: 0, length: length), of: storage, style: style)
            }
            storage.endEditing()
            isReplacingText = false

            text = newText
            undoManager.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            scrollView.scrollToTop()
            lineNumbers.reloadLines()
            if let tokens {
                painted.commit(tokens)
            } else {
                scheduleHighlight(after: .zero)
            }
        }

        public func textDidChange(_ notification: Notification) {
            takeIn(currentText())
        }

        @objc private func undoDidChangeText(_ notification: Notification) {
            let current = currentText()
            if current != text {
                takeIn(current)
            }
        }

        /// Takes in the text after an edit: writes it back, and updates the gutter, the
        /// current line and highlighting, and the idle call.
        private func takeIn(_ newText: String) {
            text = newText
            configuration.text = text
            lineNumbers.refresh()
            textView.setNeedsLineHighlightUpdate()
            scheduleHighlight(after: Self.highlightDelay)
            idle.schedule { [weak self] in
                self?.fireIdle()
            }
        }

        public func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        /// The text as a native Swift string, copied in one go. A string bridged from the text
        /// storage reads one character at a time through Objective-C, which makes every
        /// comparison SwiftUI does and every pass of the highlighter slow on long files.
        private func currentText() -> String {
            guard let characters = textView.textStorage?.mutableString, characters.length > 0 else { return "" }
            return withUnsafeTemporaryAllocation(of: unichar.self, capacity: characters.length) { buffer in
                guard let base = buffer.baseAddress else { return "" }
                characters.getCharacters(base, range: NSRange(location: 0, length: buffer.count))
                return String(decoding: buffer, as: UTF16.self)
            }
        }

        private func fireIdle() {
            configuration.onIdle(text)
        }

        /// Makes a pending idle call now, after the current SwiftUI update.
        private func flushIdle() {
            guard idle.isPending else { return }
            idle.cancel()
            let text = text
            let onIdle = configuration.onIdle
            Task { @MainActor in
                onIdle(text)
            }
        }

        @objc private func visibleAreaDidChange(_ notification: Notification) {
            lineNumbers.needsDisplay = true
        }

        // MARK: Highlighting

        private func normalizedTokens(in text: String, length: Int) -> [SyntaxToken] {
            TokenNormalizer.normalize(highlighter.tokens(in: text), length: length, keeping: style.styledKinds)
        }

        private func scheduleHighlight(after delay: Duration) {
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                    if Task.isCancelled { return }
                }
                await self?.highlight()
            }
        }

        /// Tokenizes a snapshot off the main thread, then repaints what changed if no edit
        /// came in meanwhile. Attribute changes leave the selection, scrolling and undo alone.
        private func highlight() async {
            guard let storage = textView.textStorage else { return }
            if textView.hasMarkedText() {
                scheduleHighlight(after: Self.highlightDelay)
                return
            }
            let snapshot = generation
            let text = currentText()
            let length = storage.length
            let highlighter = highlighter
            let kinds = style.styledKinds
            let tokens = await Task.detached(priority: .userInitiated) {
                TokenNormalizer.normalize(highlighter.tokens(in: text), length: length, keeping: kinds)
            }.value
            guard !Task.isCancelled, snapshot == generation, !textView.hasMarkedText() else { return }
            repaint(with: tokens)
        }

        /// Highlights at once, on the main thread, after an edit made for a command, so the
        /// lines it changed never show unpainted. Long text is highlighted off it, as usual.
        private func highlightNow() {
            guard let storage = textView.textStorage, storage.length <= Self.synchronousHighlightLimit,
                  !textView.hasMarkedText() else {
                scheduleHighlight(after: .zero)
                return
            }
            highlightTask?.cancel()
            repaint(with: normalizedTokens(in: text, length: storage.length))
        }

        /// Repaints what differs from `tokens`, which are normalized for the current text.
        private func repaint(with tokens: [SyntaxToken]) {
            guard let storage = textView.textStorage else { return }
            guard let range = painted.repaintRange(for: tokens, length: storage.length) else {
                painted.commit(tokens)
                return
            }
            storage.beginEditing()
            TokenPainter.paint(tokens, in: range, of: storage, style: style)
            storage.endEditing()
            painted.commit(tokens)
        }

        /// Repaints everything with the current style, after a font change.
        private func repaintAll() {
            guard let storage = textView.textStorage else { return }
            storage.beginEditing()
            TokenPainter.paint(painted.tokens, in: NSRange(location: 0, length: storage.length), of: storage, style: style)
            storage.endEditing()
            painted.commit(painted.tokens)
        }
    }
}

extension CodeEditorView.Coordinator: @MainActor NSTextStorageDelegate {
    public func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters), !isReplacingText else { return }
        painted.noteEdit(in: editedRange, changeInLength: delta)
        lineNumbers.noteEdit(in: editedRange, changeInLength: delta)
        generation += 1
    }
}

/// Keeps the text view at least as tall as the visible area, so a click below the last line
/// still lands in it, and keeps the first line in view when the find bar opens over it.
final class CodeScrollView: NSScrollView {
    private var topInset: CGFloat = 0

    /// Scrolls to the first line, below anything that covers the top, such as the find bar.
    func scrollToTop() {
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: -contentView.contentInsets.top))
        reflectScrolledClipView(contentView)
    }

    override func tile() {
        let wasAtTop = contentView.bounds.minY <= -topInset + 0.5
        super.tile()
        let inset = contentView.contentInsets.top
        if inset != topInset {
            topInset = inset
            if wasAtTop {
                scrollToTop()
            }
        }
        guard let textView = documentView as? NSTextView else { return }
        let height = contentSize.height
        if textView.minSize.height != height {
            textView.minSize = NSSize(width: 0, height: height)
        }
    }
}
