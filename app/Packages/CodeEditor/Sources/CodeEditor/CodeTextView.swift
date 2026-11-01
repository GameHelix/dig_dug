import AppKit
import SyntaxCore

/// The editor's text view on TextKit 2: SF Mono, tabs four spaces wide, gofmt-style
/// indentation and a current-line highlight. It never touches `layoutManager`, which would
/// switch it back to TextKit 1.
final class CodeTextView: NSTextView {
    var style = EditorStyle(fontSize: 13) {
        didSet { applyStyle() }
    }

    weak var lineNumberView: LineNumberRulerView?

    /// How the file shown comments out and indents lines.
    var lineSyntax = LineSyntax.plainText

    /// Called after `apply` changed the text, so highlighting can follow before it is drawn.
    var didApplyEdit: (() -> Void)?

    /// Called with the index of the word character under the pointer when the code is clicked
    /// with Option held, for Quick Help; the click then leaves the selection as it was. Off a
    /// word (wordIndex), Option-click is an ordinary click.
    var onOptionClick: ((Int) -> Void)?

    private var highlightedLineRect = NSRect.zero
    private var lineHighlightUpdatePending = false

    func configure() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        allowsDocumentBackgroundColorChange = false
        allowsUndo = true
        isSelectable = true
        displaysLinkToolTips = false

        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        enabledTextCheckingTypes = 0
        inlinePredictionType = .no
        mathExpressionCompletionType = .no
        writingToolsBehavior = .none

        usesFindBar = true
        isIncrementalSearchingEnabled = true

        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainerInset = NSSize(width: 2, height: 6)
        applyStyle()
    }

    private func applyStyle() {
        defaultParagraphStyle = style.paragraphStyle
        typingAttributes = style.baseAttributes
        backgroundColor = style.theme.background
        insertionPointColor = style.theme.insertionPoint
        selectedTextAttributes = [.backgroundColor: style.theme.selection]
        needsDisplay = true
    }

    // Typed text starts plain; highlighting colors it a moment later.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set { super.typingAttributes = style.baseAttributes }
    }

    override var isEditable: Bool {
        didSet { setNeedsLineHighlightUpdate() }
    }

    // MARK: Indentation

    override func insertNewline(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else {
            super.insertNewline(sender)
            return
        }
        let edit = Indentation.newline(in: characters, selection: selectedRange())
        super.insertText(edit.replacement, replacementRange: edit.range)
        if let selection = edit.selection {
            setSelectedRange(selection)
        }
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string
        if isEditable, !hasMarkedText(), replacementRange.location == NSNotFound,
           let typed, Indentation.closingBrackets.contains(typed),
           let edit = Indentation.closingBracket(typed, in: characters, selection: selectedRange()) {
            super.insertText(edit.replacement, replacementRange: edit.range)
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
    }

    /// The text's characters, read in place without copying.
    var characters: NSString {
        textStorage?.mutableString ?? ""
    }

    // Tab indents the lines of a selection that reaches into another line; elsewhere it
    // inserts a tab.
    override func insertTab(_ sender: Any?) {
        if isEditable, !hasMarkedText(), Lines.spanLines(selectedRange(), in: characters) {
            indentLines()
            return
        }
        super.insertTab(sender)
    }

    // A text view that is not a field editor does nothing with Shift-Tab; here it outdents
    // the selected lines, or the insertion point's line.
    override func insertBacktab(_ sender: Any?) {
        if isEditable, !hasMarkedText() {
            outdentLines()
            return
        }
        super.insertBacktab(sender)
    }

    // Escape would offer dictionary words, which mean nothing in code.
    override func complete(_ sender: Any?) {}

    // MARK: Quick Help

    // Option-click asks about the code under the pointer, as in Xcode; Option-drag still
    // selects a rectangle.
    override func mouseDown(with event: NSEvent) {
        if let onOptionClick, event.clickCount == 1,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .option,
           let index = wordIndex(at: convert(event.locationInWindow, from: nil)) {
            onOptionClick(index)
            return
        }
        super.mouseDown(with: event)
    }

    /// The index of the word character drawn under `point`, in the view's coordinates: a letter,
    /// a digit, an underscore, or anything beyond ASCII. Nil anywhere else, such as on
    /// punctuation or in the blank space past the end of a line, where Option-click is an
    /// ordinary click.
    func wordIndex(at point: NSPoint) -> Int? {
        let insertion = characterIndexForInsertion(at: point)
        guard insertion != NSNotFound else { return nil }
        let text = string as NSString
        // The insertion point nearest the pointer is on one side or the other of the character
        // under it.
        for index in [insertion, insertion - 1] where index >= 0 && index < text.length {
            guard let rect = rect(for: NSRange(location: index, length: 1)), rect.contains(point) else { continue }
            let c = text.character(at: index)
            let word = (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80
            return word ? index : nil
        }
        return nil
    }

    /// Where `range` is drawn, in the view's coordinates: its first line, for a range that wraps.
    func rect(for range: NSRange) -> NSRect? {
        guard let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        layoutManager.ensureLayout(for: textRange)
        var frame: CGRect?
        layoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segmentFrame, _, _ in
            frame = segmentFrame
            return false
        }
        guard let frame else { return nil }
        return frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: Line commands

    /// Indents the selected lines, or the insertion point's line, by one level of the file's
    /// indentation. Returns whether the text changed.
    @discardableResult
    func indentLines() -> Bool {
        guard isEditable,
              let edit = Indentation.indent(characters, selection: selectedRange(), unit: lineSyntax.indentUnit(in: characters))
        else { return false }
        return apply(edit, actionName: "Indent")
    }

    /// Takes one level of indentation off the selected lines, or the insertion point's line.
    @discardableResult
    func outdentLines() -> Bool {
        guard isEditable,
              let edit = Indentation.outdent(characters, selection: selectedRange(), unit: lineSyntax.indentUnit(in: characters))
        else { return false }
        return apply(edit, actionName: "Outdent")
    }

    /// Comments out the selected lines, or the insertion point's line, or uncomments them.
    @discardableResult
    func toggleLineComments() -> Bool {
        guard isEditable, let marker = lineSyntax.commentMarker,
              let edit = LineComments.toggle(marker, in: characters, selection: selectedRange())
        else { return false }
        return apply(edit, actionName: "Toggle Comment")
    }

    /// Makes an edit as one step of its own on the undo stack, named `actionName` in the Edit
    /// menu, and selects what the edit says. Like typing, it tells the delegate the text
    /// changed. Returns false when the text cannot change, such as when it is read-only.
    @discardableResult
    func apply(_ edit: TextEdit, actionName: String) -> Bool {
        guard isEditable, let storage = textStorage else { return false }
        if hasMarkedText() {
            unmarkText()
        }
        // Typing before and after the edit stays out of its undo step.
        breakUndoCoalescing()
        let undo = undoManager
        // The step closes here rather than when the current event ends: an edit made after
        // its event, such as gofmt's output, would otherwise share a step with what comes next.
        let groupsByEvent = undo?.groupsByEvent ?? false
        if let undo, undo.groupingLevel == 0 {
            undo.groupsByEvent = false
        }
        undo?.beginUndoGrouping()
        let allowed = shouldChangeText(in: edit.range, replacementString: edit.replacement)
        if allowed {
            storage.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: style.baseAttributes))
            didChangeText()
            undo?.setActionName(actionName)
        }
        undo?.endUndoGrouping()
        undo?.groupsByEvent = groupsByEvent
        guard allowed else { return false }
        setSelectedRange(edit.selection ?? NSRange(location: edit.range.location + (edit.replacement as NSString).length, length: 0))
        breakUndoCoalescing()
        didApplyEdit?()
        return true
    }

    // MARK: Text checking

    // Edit menus and the substitutions panel offer these; code never wants them on.
    private static let refusedActions: Set<Selector> = [
        #selector(toggleAutomaticQuoteSubstitution(_:)),
        #selector(toggleAutomaticDashSubstitution(_:)),
        #selector(toggleAutomaticTextReplacement(_:)),
        #selector(toggleAutomaticSpellingCorrection(_:)),
        #selector(toggleContinuousSpellChecking(_:)),
        #selector(toggleGrammarChecking(_:)),
        #selector(toggleSmartInsertDelete(_:)),
        #selector(toggleAutomaticLinkDetection(_:)),
        #selector(toggleAutomaticDataDetection(_:)),
        #selector(toggleAutomaticTextCompletion(_:)),
        #selector(checkSpelling(_:)),
        #selector(showGuessPanel(_:)),
        #selector(orderFrontSubstitutionsPanel(_:)),
    ]

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action, Self.refusedActions.contains(action) {
            return false
        }
        return super.validateMenuItem(menuItem)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.refusedActions.contains(action) {
            return false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {}
    override func toggleAutomaticDashSubstitution(_ sender: Any?) {}
    override func toggleAutomaticTextReplacement(_ sender: Any?) {}
    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {}
    override func toggleContinuousSpellChecking(_ sender: Any?) {}
    override func toggleGrammarChecking(_ sender: Any?) {}
    override func toggleSmartInsertDelete(_ sender: Any?) {}
    override func toggleAutomaticLinkDetection(_ sender: Any?) {}
    override func toggleAutomaticDataDetection(_ sender: Any?) {}
    override func toggleAutomaticTextCompletion(_ sender: Any?) {}
    override func checkSpelling(_ sender: Any?) {}
    override func showGuessPanel(_ sender: Any?) {}
    override func orderFrontSubstitutionsPanel(_ sender: Any?) {}

    // MARK: Current line

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        setNeedsLineHighlightUpdate()
    }

    override func textViewportLayoutControllerDidLayout(_ textViewportLayoutController: NSTextViewportLayoutController) {
        super.textViewportLayoutControllerDidLayout(textViewportLayoutController)
        lineNumberView?.needsDisplay = true
        setNeedsLineHighlightUpdate()
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let lineRect = currentLineRect() ?? .zero
        highlightedLineRect = lineRect
        guard lineRect.intersects(rect) else { return }
        style.theme.currentLine.setFill()
        lineRect.intersection(rect).fill(using: .sourceOver)
    }

    /// Redraws the current-line band and the gutter once the current event is handled, when
    /// layout is settled.
    func setNeedsLineHighlightUpdate() {
        guard !lineHighlightUpdatePending else { return }
        lineHighlightUpdatePending = true
        Task { @MainActor [weak self] in
            self?.updateLineHighlight()
        }
    }

    private func updateLineHighlight() {
        lineHighlightUpdatePending = false
        lineNumberView?.needsDisplay = true
        let lineRect = currentLineRect() ?? .zero
        guard lineRect != highlightedLineRect else { return }
        setNeedsDisplay(highlightedLineRect)
        setNeedsDisplay(lineRect)
        highlightedLineRect = lineRect
    }

    /// The band across the whole width behind the line that holds the insertion point, or nil
    /// when there is a selection or the text is read-only. A wrapped line is one band.
    func currentLineRect() -> NSRect? {
        guard isEditable, let layoutManager = textLayoutManager, let content = layoutManager.textContentManager,
              let storage = textStorage else { return nil }
        let selection = selectedRange()
        guard selection.length == 0 else { return nil }

        var frame: CGRect?
        let length = storage.length
        if selection.location >= length, length == 0 || Self.isParagraphBreak(characters.character(at: length - 1)) {
            // The empty last line after a trailing newline.
            layoutManager.enumerateTextSegments(
                in: NSTextRange(location: content.documentRange.endLocation), type: .standard, options: []
            ) { _, segmentFrame, _, _ in
                frame = segmentFrame
                return false
            }
        } else if let location = content.location(content.documentRange.location, offsetBy: min(selection.location, length - 1)),
                  let fragment = layoutManager.textLayoutFragment(for: location) {
            var fragmentFrame = fragment.layoutFragmentFrame
            let lines = fragment.textLineFragments
            if lines.count > 1, let last = lines.last, last.characterRange.length == 0 {
                // Leave out the extra line fragment after a trailing newline.
                fragmentFrame.size.height = last.typographicBounds.minY
            }
            frame = fragmentFrame
        }
        guard let frame else { return nil }
        return NSRect(x: 0, y: frame.minY + textContainerOrigin.y, width: bounds.width, height: frame.height)
    }

    nonisolated static func isParagraphBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029
    }
}
