import AppKit
import SwiftUI
import SyntaxCore

/// A code editor: an NSTextView on TextKit 2 with SF Mono, line numbers, a current-line
/// highlight, the find bar, undo, gofmt-style indentation and highlighting in Xcode's colors.
public struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String
    let highlighter: any SyntaxHighlighting
    let fontSize: CGFloat
    let isEditable: Bool
    let showsLineNumbers: Bool
    let accessibilityLabel: String
    let onIdle: @MainActor (String) -> Void

    /// - Parameters:
    ///   - text: The code. The editor writes every edit back at once.
    ///   - highlighter: Turns the code into tokens, off the main thread. Passing a highlighter
    ///     of another type highlights the code again.
    ///   - fontSize: The size of SF Mono, in points.
    ///   - isEditable: Whether the code can be edited. Read-only code can still be selected,
    ///     copied and searched.
    ///   - showsLineNumbers: Whether the gutter with line numbers shows.
    ///   - accessibilityLabel: What VoiceOver calls the editor.
    ///   - onIdle: Called with the code one second after typing stops. A pending call is made
    ///     at once when the text is replaced from outside or the editor goes away.
    public init(
        text: Binding<String>,
        highlighter: any SyntaxHighlighting,
        fontSize: CGFloat = 13,
        isEditable: Bool = true,
        showsLineNumbers: Bool = true,
        accessibilityLabel: String = "Code editor",
        onIdle: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        _text = text
        self.highlighter = highlighter
        self.fontSize = fontSize
        self.isEditable = isEditable
        self.showsLineNumbers = showsLineNumbers
        self.accessibilityLabel = accessibilityLabel
        self.onIdle = onIdle
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
        private var text = ""
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
            textView.isEditable = configuration.isEditable
            textView.setAccessibilityLabel(configuration.accessibilityLabel)
            textView.delegate = self
            textView.textStorage?.delegate = self

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

            replaceText(with: configuration.text)
        }

        func update(_ newConfiguration: CodeEditorView) {
            let textChanged = newConfiguration.text != text
            if textChanged {
                // A pending idle call belongs to the text being replaced.
                flushIdle()
            }
            configuration = newConfiguration

            if textView.isEditable != newConfiguration.isEditable {
                textView.isEditable = newConfiguration.isEditable
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

        func dismantle() {
            highlightTask?.cancel()
            flushIdle()
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
            text = currentText()
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
