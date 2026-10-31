import AppKit

/// The gutter. It numbers each line beside its first line fragment, reading positions from
/// TextKit 2 layout and numbers from a line index, so it only touches the visible lines.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: CodeTextView?
    private var lines = LineIndex()

    private static let leadingPadding: CGFloat = 14
    private static let trailingPadding: CGFloat = 8

    init(textView: CodeTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        // Views no longer clip their drawing by default; the gutter must not paint over the text.
        clipsToBounds = true
        setAccessibilityElement(false)
        textView.lineNumberView = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("LineNumberRulerView is not loaded from archives")
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var requiredThickness: CGFloat { ruleThickness }

    /// Reads every line start again, after the whole text was replaced.
    func reloadLines() {
        guard let storage = textView?.textStorage else { return }
        lines = LineIndex(storage.mutableString)
        refresh()
    }

    /// Updates line starts for an edit, as the text storage reports it while processing.
    func noteEdit(in editedRange: NSRange, changeInLength delta: Int) {
        guard let storage = textView?.textStorage else { return }
        let oldRange = NSRange(location: editedRange.location, length: editedRange.length - delta)
        lines.replaceCharacters(in: oldRange, newLength: editedRange.length, text: storage.mutableString)
    }

    /// Resizes and redraws the gutter, after an edit or a font change.
    func refresh() {
        updateThickness()
        needsDisplay = true
    }

    /// Fits the gutter to the font size and the number of digits.
    private func updateThickness() {
        guard let font = textView?.style.lineNumberFont else { return }
        let digits = max(2, String(lines.count).count)
        let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        let thickness = (CGFloat(digits) * digitWidth + Self.leadingPadding + Self.trailingPadding).rounded(.up)
        if ruleThickness != thickness {
            ruleThickness = thickness
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {}

    override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }
        let area = dirtyRect.intersection(bounds)
        textView.style.theme.background.setFill()
        area.fill()
        drawLineNumbers(in: area, of: textView)
    }

    private func drawLineNumbers(in dirtyRect: NSRect, of textView: CodeTextView) {
        guard let layoutManager = textView.textLayoutManager, let content = layoutManager.textContentManager else { return }
        let style = textView.style
        let containerOrigin = textView.textContainerOrigin
        let area = convert(dirtyRect, to: textView)
        let top = area.minY - containerOrigin.y
        let bottom = area.maxY - containerOrigin.y
        let selectedLines = textView.isEditable ? lines.lines(covering: textView.selectedRange()) : nil
        let plain: [NSAttributedString.Key: Any] = [.font: style.lineNumberFont, .foregroundColor: style.theme.lineNumber]
        let current: [NSAttributedString.Key: Any] = [.font: style.lineNumberFont, .foregroundColor: style.theme.currentLineNumber]
        let ascender = style.lineNumberFont.ascender
        let right = bounds.maxX - Self.trailingPadding

        let documentStart = content.documentRange.location
        var start = layoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(top, 0)))?.rangeInElement.location
        if start == nil, top > 0 {
            // Below the text: only the last line, or the empty one after it, can show.
            layoutManager.enumerateTextLayoutFragments(
                from: content.documentRange.endLocation, options: [.reverse, .ensuresExtraLineFragment]
            ) { fragment in
                start = fragment.rangeInElement.location
                return false
            }
        }
        layoutManager.enumerateTextLayoutFragments(
            from: start ?? documentStart, options: [.ensuresExtraLineFragment]
        ) { fragment in
            let frame = fragment.layoutFragmentFrame
            guard frame.minY <= bottom else { return false }
            let line = lines.line(containing: content.offset(from: documentStart, to: fragment.rangeInElement.location))
            for (index, lineFragment) in fragment.textLineFragments.enumerated() {
                // The first line fragment starts the line; an empty one after it is the extra
                // line that follows a trailing newline. The rest are wrapped continuations.
                let isExtraLine = index > 0 && lineFragment.characterRange.length == 0
                guard index == 0 || isExtraLine else { continue }
                let number = isExtraLine ? line + 1 : line
                let baseline = frame.minY + lineFragment.typographicBounds.minY + lineFragment.glyphOrigin.y + containerOrigin.y
                let y = convert(NSPoint(x: 0, y: baseline), from: textView).y - ascender
                let label = String(number + 1) as NSString
                let attributes = selectedLines?.contains(number) == true ? current : plain
                let width = label.size(withAttributes: attributes).width
                label.draw(at: NSPoint(x: right - width, y: y), withAttributes: attributes)
            }
            return true
        }
    }
}
