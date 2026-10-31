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
        if let insertionPoint = edit.insertionPoint {
            setSelectedRange(NSRange(location: insertionPoint, length: 0))
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
    private var characters: NSString {
        textStorage?.mutableString ?? ""
    }

    // Escape would offer dictionary words, which mean nothing in code.
    override func complete(_ sender: Any?) {}

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

    static func isParagraphBreak(_ character: unichar) -> Bool {
        character == 0x0A || character == 0x0D || character == 0x2029
    }
}
