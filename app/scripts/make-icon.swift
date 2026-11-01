// Draws Gopherwood's icon at every size of a macOS iconset: a gopher and a tree in Go Blue on
// deep green, in the macOS rounded square. Each size is drawn on its own pixel grid, with
// fewer details at 16 and 32 px, so it stays sharp.
// Usage: make-icon <iconset folder>   (scripts/make-icon.sh runs it)

import AppKit
import SwiftUI

let goBlue = NSColor(srgbRed: 0x00 / 255, green: 0xAD / 255, blue: 0xD8 / 255, alpha: 1)
let goBlueLight = NSColor(srgbRed: 0x8F / 255, green: 0xE0 / 255, blue: 0xF2 / 255, alpha: 1)
let deepGreen = NSColor(srgbRed: 0x0C / 255, green: 0x3B / 255, blue: 0x2B / 255, alpha: 1)
let groundGreen = NSColor(srgbRed: 0x12 / 255, green: 0x4B / 255, blue: 0x37 / 255, alpha: 1)
let ink = NSColor(srgbRed: 0x06 / 255, green: 0x22 / 255, blue: 0x19 / 255, alpha: 1)

/// The macOS icon grid's rounded square, with Apple's continuous corners.
func squircle(_ rect: CGRect) -> CGPath {
    RoundedRectangle(cornerRadius: rect.width * 0.225, style: .continuous).path(in: rect).cgPath
}

func render(pixels n: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: n, height: n)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(true)
    let s = CGFloat(n) / 1024
    // Snap to whole pixels at small sizes, so edges are crisp.
    func p(_ v: CGFloat) -> CGFloat { n <= 32 ? (v * s).rounded() : v * s }
    func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> CGRect {
        CGRect(x: p(x - r), y: p(y - r), width: p(x + r) - p(x - r), height: p(y + r) - p(y - r))
    }
    let small = n <= 32

    // The tile: a soft shadow under the rounded square, as macOS icons have.
    let tile = CGRect(x: p(100), y: p(100), width: p(924) - p(100), height: p(924) - p(100))
    let shape = squircle(tile)
    if n >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(deepGreen.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.setFillColor(deepGreen.cgColor)
    ctx.fill(tile)

    // Layer: the ground, a low hill.
    ctx.setFillColor(groundGreen.cgColor)
    ctx.fillEllipse(in: CGRect(x: p(-40), y: p(-260), width: p(1104) - p(-40), height: p(470) - p(-260)))

    // Layer: the tree, a pine of three tiers on a short trunk.
    ctx.setFillColor(goBlue.cgColor)
    ctx.fill(CGRect(x: p(656), y: p(236), width: p(712) - p(656), height: p(360) - p(236)))
    let tiers: [(base: CGFloat, half: CGFloat, apex: CGFloat)] = small
        ? [(330, 230, 860)]
        : [(330, 220, 610), (500, 175, 740), (650, 128, 862)]
    for tier in tiers {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: p(684 - tier.half), y: p(tier.base)))
        path.addLine(to: CGPoint(x: p(684 + tier.half), y: p(tier.base)))
        path.addLine(to: CGPoint(x: p(684), y: p(tier.apex)))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setLineJoin(.round)
        ctx.setLineWidth(small ? 0 : 30 * s)
        ctx.setStrokeColor(goBlue.cgColor)
        ctx.drawPath(using: small ? .fill : .fillStroke)
    }

    // Layer: the gopher, peeking up, outlined in deep green against the tree.
    let head = circle(392, 300, 196)
    let ears = [circle(250, 450, 56), circle(534, 450, 56)]
    ctx.setFillColor(deepGreen.cgColor)
    let outline: CGFloat = small ? 1 : 18
    for e in ears + [head] { ctx.fillEllipse(in: e.insetBy(dx: -outline * (small ? 1 : s), dy: -outline * (small ? 1 : s))) }
    ctx.setFillColor(goBlue.cgColor)
    for e in ears { ctx.fillEllipse(in: e) }
    ctx.fillEllipse(in: head)
    if !small {
        ctx.setFillColor(goBlueLight.cgColor)
        for e in ears { ctx.fillEllipse(in: e.insetBy(dx: 18 * s, dy: 18 * s)) }
    }

    // Eyes: big and white, the Go gopher's mark.
    let eyeR: CGFloat = n <= 16 ? 0 : (small ? 46 : 58)
    if eyeR > 0 {
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: circle(318, 352, eyeR))
        ctx.fillEllipse(in: circle(466, 352, eyeR))
        if !small {
            let detailed = n >= 128
            ctx.setFillColor(ink.cgColor)
            ctx.fillEllipse(in: circle(336, 346, detailed ? 26 : 30))
            ctx.fillEllipse(in: circle(484, 346, detailed ? 26 : 30))
            if detailed {
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: circle(344, 356, 8))
                ctx.fillEllipse(in: circle(492, 356, 8))
            }
            // Snout, nose and teeth.
            ctx.setFillColor(goBlueLight.cgColor)
            ctx.fillEllipse(in: CGRect(x: p(318), y: p(196), width: p(466) - p(318), height: p(292) - p(196)))
            if detailed {
                ctx.setFillColor(ink.cgColor)
                ctx.fillEllipse(in: CGRect(x: p(366), y: p(258), width: p(418) - p(366), height: p(292) - p(258)))
            }
            ctx.setFillColor(NSColor.white.cgColor)
            let teeth = CGRect(x: p(370), y: p(184), width: p(414) - p(370), height: p(236) - p(184))
            ctx.addPath(CGPath(roundedRect: teeth, cornerWidth: 6 * s, cornerHeight: 6 * s, transform: nil))
            ctx.fillPath()
            ctx.setFillColor(goBlueLight.cgColor)
            ctx.fill(CGRect(x: p(390), y: p(184), width: max(1, p(394) - p(390)), height: p(236) - p(184)))
        }
    }

    // A thin light rim along the top edge, for a glassy edge.
    if n >= 128 {
        ctx.addPath(shape)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.setLineWidth(6 * s)
        ctx.strokePath()
    }
    ctx.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon <iconset folder>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let png = render(pixels: pixels).representation(using: .png, properties: [:]) else { exit(1) }
        try png.write(to: folder.appendingPathComponent(name))
    }
}
