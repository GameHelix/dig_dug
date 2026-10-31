import AppKit
import SwiftUI
import SyntaxCore
import Testing

@testable import CodeEditor

/// A color as "#RRGGBB", or "#RRGGBB@alpha" when it is not opaque.
func hex(_ color: NSColor) -> String {
    guard let srgb = color.usingColorSpace(.sRGB) else { return "unresolved" }
    func byte(_ component: CGFloat) -> Int { Int((component * 255).rounded()) }
    var result = String(format: "#%02X%02X%02X", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
    if srgb.alphaComponent < 1 {
        result += String(format: "@%.2f", srgb.alphaComponent)
    }
    return result
}

/// A dynamic color as hex, resolved in an appearance.
func hex(_ color: NSColor, in appearance: NSAppearance.Name) -> String {
    var result = "unresolved"
    NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
        result = hex(color)
    }
    return result
}

/// Hands back the tokens it was made with.
struct FixedHighlighter: SyntaxHighlighting {
    let fixed: [SyntaxToken]

    func tokens(in text: String) -> [SyntaxToken] { fixed }
}

@Suite struct SyntaxThemeTests {
    let theme = SyntaxTheme.xcode

    @Test(arguments: [
        (SyntaxKind.keyword, "#9B2393", "#FC5FA3"),
        (.typeName, "#3900A0", "#D0A8FF"),
        (.builtin, "#6C36A9", "#A167E6"),
        (.function, "#326D74", "#67B7A4"),
        (.string, "#C41A16", "#FC6A5D"),
        (.number, "#1C00CF", "#D0BF69"),
        (.comment, "#5D6C79", "#6C7986"),
        (.plain, "#000000@0.85", "#FFFFFF@0.85"),
        (.operator, "#000000@0.85", "#FFFFFF@0.85"),
        (.punctuation, "#000000@0.85", "#FFFFFF@0.85"),
    ])
    func kindsUseXcodeDefaultColors(kind: SyntaxKind, light: String, dark: String) {
        #expect(hex(theme.color(for: kind), in: .aqua) == light)
        #expect(hex(theme.color(for: kind), in: .darkAqua) == dark)
    }

    @Test func editorColorsFollowXcode() {
        #expect(hex(theme.background, in: .aqua) == "#FFFFFF")
        #expect(hex(theme.background, in: .darkAqua) == "#1F1F24")
        #expect(hex(theme.currentLine, in: .aqua) == "#E8F2FE")
        #expect(hex(theme.currentLine, in: .darkAqua) == "#23252B")
        #expect(hex(theme.selection, in: .aqua) == "#A4CDFF")
        #expect(hex(theme.selection, in: .darkAqua) == "#515B70")
        #expect(hex(theme.insertionPoint, in: .aqua) == "#000000")
        #expect(hex(theme.insertionPoint, in: .darkAqua) == "#FFFFFF")
    }

    @Test func increaseContrastStrengthensPlainTextAndComments() {
        // A high-contrast appearance cannot be made by name, so check the variants directly.
        #expect(hex(theme.swatch(for: .plain).color(in: .lightContrast)) == "#000000")
        #expect(hex(theme.swatch(for: .plain).color(in: .darkContrast)) == "#FFFFFF")
        #expect(hex(theme.swatch(for: .comment).color(in: .lightContrast)) == "#45515C")
        #expect(hex(theme.swatch(for: .comment).color(in: .darkContrast)) == "#95A2AE")
        #expect(hex(theme.swatch(for: .keyword).color(in: .darkContrast)) == "#FC5FA3")
        #expect(hex(theme.swatch(for: .operator).color(in: .light)) == "#000000@0.85")
    }

    @Test func appearancesPickTheirVariant() {
        #expect(NSAppearance(named: .aqua).map(SyntaxTheme.Swatch.variant(of:)) == .light)
        #expect(NSAppearance(named: .darkAqua).map(SyntaxTheme.Swatch.variant(of:)) == .dark)
        #expect(NSAppearance(named: .vibrantDark).map(SyntaxTheme.Swatch.variant(of:)) == .dark)
    }

    @Test func keywordsAreBoldAndEverythingIsSFMono() {
        for kind in SyntaxKind.allCases {
            let font = theme.font(for: kind, size: 14)
            let systemMono = NSFont.monospacedSystemFont(ofSize: 14, weight: kind == .keyword ? .bold : .regular)
            #expect(font.fontName == systemMono.fontName)
            #expect(font.isFixedPitch)
            #expect(font.pointSize == 14)
            #expect(font.fontDescriptor.symbolicTraits.contains(.bold) == (kind == .keyword))
            #expect(theme.isBold(kind) == (kind == .keyword))
        }
    }

    @Test func onlyColoredKindsAreStyled() {
        #expect(theme.styledKinds == [.keyword, .typeName, .builtin, .function, .string, .number, .comment])
    }

    @Test func attributesCarryFontAndColor() {
        let attributes = theme.attributes(for: .string, size: 13)
        #expect((attributes[.font] as? NSFont)?.pointSize == 13)
        #expect((attributes[.foregroundColor] as? NSColor) === theme.color(for: .string))
    }

    @Test func attributedStringStylesRunsAtUTF16Offsets() {
        // "func" starts at UTF-16 offset 3, after an emoji that takes two code units.
        let code = "😀 func f() // done"
        let highlighter = FixedHighlighter(fixed: [
            SyntaxToken(range: NSRange(location: 3, length: 4), kind: .keyword),
            SyntaxToken(range: NSRange(location: 8, length: 1), kind: .function),
            SyntaxToken(range: NSRange(location: 12, length: 7), kind: .comment),
        ])
        let result = theme.attributedString(for: code, highlighter: highlighter, fontSize: 13)
        let fonts = result.runs[AttributeScopes.SwiftUIAttributes.FontAttribute.self].map { font, range in
            (String(result[range].characters), font)
        }
        #expect(fonts.map(\.0) == ["😀 ", "func", " f() // done"])
        #expect(fonts[1].1 == .system(size: 13, weight: .bold, design: .monospaced))
        #expect(fonts[0].1 == .system(size: 13, weight: .regular, design: .monospaced))

        let colors = result.runs[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self].map { color, range in
            (String(result[range].characters), color)
        }
        #expect(colors.map(\.0) == ["😀 ", "func", " ", "f", "() ", "// done"])
        #expect(colors[1].1 == Color(nsColor: theme.color(for: .keyword)))
        #expect(colors[3].1 == Color(nsColor: theme.color(for: .function)))
        #expect(colors[5].1 == Color(nsColor: theme.color(for: .comment)))
        #expect(colors[0].1 == Color(nsColor: theme.color(for: .plain)))
    }

    @Test func attributedStringIgnoresBadTokens() {
        let highlighter = FixedHighlighter(fixed: [
            SyntaxToken(range: NSRange(location: 2, length: 50), kind: .string),
            SyntaxToken(range: NSRange(location: NSNotFound, length: 1), kind: .number),
        ])
        let result = theme.attributedString(for: "a \"b\"", highlighter: highlighter)
        let colors = result.runs[AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self].map { color, range in
            (String(result[range].characters), color)
        }
        #expect(colors.map(\.0) == ["a ", "\"b\""])
        #expect(colors[1].1 == Color(nsColor: theme.color(for: .string)))
    }
}
