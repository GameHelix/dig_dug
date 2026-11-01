import AppKit
import SwiftUI
import SyntaxCore

/// Colors and weights for code, from Xcode's default light and dark themes.
///
/// Every color is dynamic: it resolves against the appearance of whatever draws it, so code
/// switches palettes live when the appearance changes.
public struct SyntaxTheme: Sendable {
    /// Xcode's "Default (Light)" and "Default (Dark)".
    public static let xcode = SyntaxTheme()

    /// The editor background.
    public let background: NSColor
    /// The band behind the line that holds the insertion point.
    public let currentLine: NSColor
    /// The background of selected text.
    public let selection: NSColor
    /// The insertion point.
    public let insertionPoint: NSColor
    /// Line numbers in the gutter.
    public let lineNumber: NSColor
    /// The numbers of the lines that hold the selection.
    public let currentLineNumber: NSColor

    private let swatches: [SyntaxKind: Swatch]
    private let plainSwatch: Swatch
    private let colors: [SyntaxKind: NSColor]
    private let plainColor: NSColor
    private let boldKinds: Set<SyntaxKind> = [.keyword]

    private init() {
        // Xcode's color for each kind, light then dark. Operators and punctuation stay plain.
        swatches = [
            .keyword: Swatch(light: .rgb(0x9B2393), dark: .rgb(0xFC5FA3)), // Keywords
            .typeName: Swatch(light: .rgb(0x3900A0), dark: .rgb(0xD0A8FF)), // Other Type Names
            .builtin: Swatch(light: .rgb(0x6C36A9), dark: .rgb(0xA167E6)), // Other Function and Method Names
            .function: Swatch(light: .rgb(0x326D74), dark: .rgb(0x67B7A4)), // Project Function and Method Names
            .string: Swatch(light: .rgb(0xC41A16), dark: .rgb(0xFC6A5D)), // Strings
            .number: Swatch(light: .rgb(0x1C00CF), dark: .rgb(0xD0BF69)), // Numbers
            // Xcode's dark comment gray is under 4.5:1 on the dark background, so Increase
            // Contrast lifts it.
            .comment: Swatch(
                light: .rgb(0x5D6C79), dark: .rgb(0x6C7986),
                lightContrast: .rgb(0x45515C), darkContrast: .rgb(0x95A2AE)
            ),
        ]
        plainSwatch = Swatch(
            light: .rgb(0x000000, alpha: 0.85), dark: .rgb(0xFFFFFF, alpha: 0.85),
            lightContrast: .rgb(0x000000), darkContrast: .rgb(0xFFFFFF)
        )
        colors = swatches.mapValues { $0.dynamicColor() }
        plainColor = plainSwatch.dynamicColor()
        background = Swatch(light: .rgb(0xFFFFFF), dark: .rgb(0x1F1F24)).dynamicColor()
        currentLine = Swatch(light: .rgb(0xE8F2FE), dark: .rgb(0x23252B)).dynamicColor()
        selection = Swatch(light: .rgb(0xA4CDFF), dark: .rgb(0x515B70)).dynamicColor()
        insertionPoint = Swatch(light: .rgb(0x000000), dark: .rgb(0xFFFFFF)).dynamicColor()
        lineNumber = Swatch(
            light: .rgb(0x000000, alpha: 0.36), dark: .rgb(0xFFFFFF, alpha: 0.36),
            lightContrast: .rgb(0x000000, alpha: 0.6), darkContrast: .rgb(0xFFFFFF, alpha: 0.6)
        ).dynamicColor()
        currentLineNumber = plainColor
    }

    /// The color for a kind of token.
    public func color(for kind: SyntaxKind) -> NSColor {
        colors[kind] ?? plainColor
    }

    /// Whether a kind of token is set in bold. Xcode sets keywords in bold.
    public func isBold(_ kind: SyntaxKind) -> Bool {
        boldKinds.contains(kind)
    }

    /// SF Mono at `size`, bold where the theme says so.
    public func font(for kind: SyntaxKind, size: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: size, weight: isBold(kind) ? .bold : .regular)
    }

    /// AppKit attributes for a kind of token: font and foreground color.
    public func attributes(for kind: SyntaxKind, size: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: font(for: kind, size: size), .foregroundColor: color(for: kind)]
    }

    /// Highlights read-only code, such as a readme code block, for SwiftUI `Text`. Runs carry
    /// SwiftUI fonts (SF Mono) and dynamic colors. For AppKit text, use `attributes(for:size:)`.
    public func attributedString(
        for code: String,
        highlighter: any SyntaxHighlighting,
        fontSize: CGFloat = 13
    ) -> AttributedString {
        let length = (code as NSString).length
        let tokens = TokenNormalizer.normalize(highlighter.tokens(in: code), length: length, keeping: styledKinds)
        var result = AttributedString(code, attributes: container(for: .plain, size: fontSize))
        for token in tokens {
            guard let range = Range(token.range, in: result) else { continue }
            result[range].setAttributes(container(for: token.kind, size: fontSize))
        }
        return result
    }

    /// The kinds that look different from plain text.
    var styledKinds: Set<SyntaxKind> {
        Set(SyntaxKind.allCases.filter { isBold($0) || swatches[$0] != nil })
    }

    /// The colors behind `color(for:)`, one for each appearance.
    func swatch(for kind: SyntaxKind) -> Swatch {
        swatches[kind] ?? plainSwatch
    }

    private func container(for kind: SyntaxKind, size: CGFloat) -> AttributeContainer {
        var container = AttributeContainer()
        container.swiftUI.font = .system(size: size, weight: isBold(kind) ? .bold : .regular, design: .monospaced)
        container.swiftUI.foregroundColor = Color(nsColor: color(for: kind))
        return container
    }
}

extension SyntaxTheme {
    /// One color for each appearance: light and dark, each also with Increase Contrast.
    struct Swatch: Sendable {
        enum Variant: CaseIterable {
            case light, dark, lightContrast, darkContrast
        }

        let light: NSColor
        let dark: NSColor
        let lightContrast: NSColor
        let darkContrast: NSColor

        init(light: NSColor, dark: NSColor, lightContrast: NSColor? = nil, darkContrast: NSColor? = nil) {
            self.light = light
            self.dark = dark
            self.lightContrast = lightContrast ?? light
            self.darkContrast = darkContrast ?? dark
        }

        func color(in variant: Variant) -> NSColor {
            switch variant {
            case .light: light
            case .dark: dark
            case .lightContrast: lightContrast
            case .darkContrast: darkContrast
            }
        }

        static func variant(of appearance: NSAppearance) -> Variant {
            let names: [NSAppearance.Name] = [
                .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ]
            switch appearance.bestMatch(from: names) {
            case .darkAqua?: return .dark
            case .accessibilityHighContrastAqua?: return .lightContrast
            case .accessibilityHighContrastDarkAqua?: return .darkContrast
            default: return .light
            }
        }

        /// A color that picks its variant from the appearance it is drawn in.
        func dynamicColor() -> NSColor {
            NSColor(name: nil) { [self] appearance in
                color(in: Self.variant(of: appearance))
            }
        }
    }
}

extension NSColor {
    fileprivate static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha
        )
    }
}
