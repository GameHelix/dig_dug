import AppKit
import SyntaxCore

/// The fonts, paragraph style and attributes the editor paints with at one font size.
struct EditorStyle {
    /// How many spaces wide a tab is.
    static let tabWidthInSpaces = 4

    let theme: SyntaxTheme
    let fontSize: CGFloat
    let font: NSFont
    let lineNumberFont: NSFont
    let paragraphStyle: NSParagraphStyle
    /// Plain text: SF Mono, the plain color and the paragraph style.
    let baseAttributes: [NSAttributedString.Key: Any]
    /// The kinds that look different from plain text; the others are painted as plain.
    let styledKinds: Set<SyntaxKind>
    private let attributesByKind: [SyntaxKind: [NSAttributedString.Key: Any]]

    init(theme: SyntaxTheme = .xcode, fontSize: CGFloat) {
        self.theme = theme
        self.fontSize = fontSize
        font = theme.font(for: .plain, size: fontSize)
        lineNumberFont = .monospacedSystemFont(ofSize: max(9, fontSize - 2), weight: .regular)

        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = []
        paragraph.defaultTabInterval = Self.tabWidth(for: font)
        paragraph.baseWritingDirection = .leftToRight
        // An immutable copy, so text storage keeps this one object instead of copying it per run.
        let paragraphStyle = paragraph.copy() as? NSParagraphStyle ?? paragraph
        self.paragraphStyle = paragraphStyle

        baseAttributes = [.font: font, .foregroundColor: theme.color(for: .plain), .paragraphStyle: paragraphStyle]
        styledKinds = theme.styledKinds
        var attributesByKind: [SyntaxKind: [NSAttributedString.Key: Any]] = [:]
        for kind in styledKinds {
            attributesByKind[kind] = baseAttributes.merging(theme.attributes(for: kind, size: fontSize)) { $1 }
        }
        self.attributesByKind = attributesByKind
    }

    /// The full set of attributes for a kind of token.
    func attributes(for kind: SyntaxKind) -> [NSAttributedString.Key: Any] {
        attributesByKind[kind] ?? baseAttributes
    }

    /// The width of a tab: four spaces of `font`.
    static func tabWidth(for font: NSFont) -> CGFloat {
        (" " as NSString).size(withAttributes: [.font: font]).width * CGFloat(tabWidthInSpaces)
    }
}
