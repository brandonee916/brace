import AppKit
import CoreGraphics
import CoreText
import Foundation

// Draws the app icon at every size macOS asks for.
//
// Kept as source rather than a pasted-in binary so the artwork is diffable and
// reproducible. This is a maintenance tool, not a setting — the icon is the app's
// identity.
//
// Usage:  makeicon <output-directory> [variant]
//         variants: dots (default), bars, single

let canvas = 1024.0

/// macOS icon grid: the rounded body sits inside the canvas so the Dock has room
/// for its shadow.
let bodyInset = 100.0
let cornerRadius = 185.4

enum Variant: String {
    case dots, bars, single
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let variantArgument = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "bars"
let variant = Variant(rawValue: variantArgument) ?? .bars

func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let deepIndigo = color(60, 54, 140)
let brightIndigo = color(120, 104, 232)
let amber = color(247, 178, 84)
let white = color(255, 255, 255)

func makeContext(size: Double) -> CGContext {
    let context = CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    return context
}

/// Draws a glyph positioned by its **ink**, not its layout box.
///
/// A layout box carries the font's ascender and descender plus side bearings, so
/// centring on it leaves the visible shape noticeably off — which is exactly what
/// happened the first time round. `CTLineGetImageBounds` gives the drawn extent,
/// so the braces can be placed symmetrically and centred for real.
func drawGlyph(
    _ text: String,
    font: NSFont,
    in context: CGContext,
    align: (CGRect) -> CGPoint
) {
    let attributed = NSAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: NSColor(cgColor: white)!,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    // The bounds come back relative to the context's current text position, which
    // after a previous draw is wherever that glyph ended. Zero it first or every
    // glyph after the first is measured against the wrong origin.
    context.textPosition = .zero
    let ink = CTLineGetImageBounds(line, context)
    context.textPosition = align(ink)
    CTLineDraw(line, context)
}

func draw(into context: CGContext, size: Double) {
    context.scaleBy(x: size / canvas, y: size / canvas)

    let body = CGRect(x: bodyInset, y: bodyInset,
                      width: canvas - bodyInset * 2, height: canvas - bodyInset * 2)
    let shape = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    context.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: [brightIndigo, deepIndigo] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )
    context.drawLinearGradient(
        CGGradient(colorsSpace: space,
                   colors: [color(255, 255, 255, 0.20), color(255, 255, 255, 0)] as CFArray,
                   locations: [0, 1])!,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.midY),
        options: []
    )
    context.restoreGState()

    let centre = CGPoint(x: canvas / 2, y: canvas / 2)

    let braceSize: Double
    let gap: Double
    switch variant {
    case .dots:   braceSize = 470; gap = 96
    case .bars:   braceSize = 470; gap = 104
    case .single: braceSize = 540; gap = 86
    }

    var braceFont = NSFont.systemFont(ofSize: braceSize, weight: .bold)
    if let rounded = braceFont.fontDescriptor.withDesign(.rounded) {
        braceFont = NSFont(descriptor: rounded, size: braceSize) ?? braceFont
    }

    // Ink-aligned: the left brace's right edge and the right brace's left edge sit
    // an equal distance from the centre line, and both are vertically centred.
    drawGlyph("{", font: braceFont, in: context) { ink in
        CGPoint(x: centre.x - gap - ink.maxX, y: centre.y - ink.midY)
    }
    drawGlyph("}", font: braceFont, in: context) { ink in
        CGPoint(x: centre.x + gap - ink.minX, y: centre.y - ink.midY)
    }

    switch variant {
    case .dots:
        let radius = 38.0, spacing = 108.0
        for (index, fill) in [white, amber, white].enumerated() {
            context.setFillColor(fill)
            let y = centre.y + spacing - Double(index) * spacing
            context.fillEllipse(in: CGRect(x: centre.x - radius, y: y - radius,
                                           width: radius * 2, height: radius * 2))
        }
    case .bars:
        let height = 56.0, spacing = 104.0
        let widths = [128.0, 152.0, 104.0]
        for (index, fill) in [white, amber, white].enumerated() {
            context.setFillColor(fill)
            let width = widths[index]
            let y = centre.y + spacing - Double(index) * spacing
            context.addPath(CGPath(roundedRect: CGRect(x: centre.x - width / 2, y: y - height / 2,
                                                       width: width, height: height),
                                   cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
            context.fillPath()
        }
    case .single:
        let radius = 62.0
        context.setFillColor(amber)
        context.fillEllipse(in: CGRect(x: centre.x - radius, y: centre.y - radius,
                                       width: radius * 2, height: radius * 2))
    }
}

func write(size: Double, to url: URL) {
    let context = makeContext(size: size)
    draw(into: context, size: size)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = NSSize(width: size, height: size)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// MARK: - Social preview card

/// GitHub's link preview wants a wide image, not a square one — 1280x640 is the
/// recommended size, and it must stay under a megabyte.
func drawSocialCard(into context: CGContext, width: Double, height: Double) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    context.drawLinearGradient(
        CGGradient(colorsSpace: space, colors: [brightIndigo, deepIndigo] as CFArray, locations: [0, 1])!,
        start: CGPoint(x: 0, y: height),
        end: CGPoint(x: width, y: 0),
        options: []
    )

    // The mark, drawn at the same proportions as the icon.
    let markSize = height * 0.52
    let markCentre = CGPoint(x: width * 0.215, y: height * 0.5)
    let braceSize = markSize * 0.72
    var braceFont = NSFont.systemFont(ofSize: braceSize, weight: .bold)
    if let rounded = braceFont.fontDescriptor.withDesign(.rounded) {
        braceFont = NSFont(descriptor: rounded, size: braceSize) ?? braceFont
    }
    let gap = markSize * 0.16
    drawGlyph("{", font: braceFont, in: context) { ink in
        CGPoint(x: markCentre.x - gap - ink.maxX, y: markCentre.y - ink.midY)
    }
    drawGlyph("}", font: braceFont, in: context) { ink in
        CGPoint(x: markCentre.x + gap - ink.minX, y: markCentre.y - ink.midY)
    }
    let barHeight = markSize * 0.086
    let spacing = markSize * 0.16
    for (index, fill) in [white, amber, white].enumerated() {
        let barWidth = [markSize * 0.196, markSize * 0.233, markSize * 0.159][index]
        context.setFillColor(fill)
        let y = markCentre.y + spacing - Double(index) * spacing
        context.addPath(CGPath(roundedRect: CGRect(x: markCentre.x - barWidth / 2, y: y - barHeight / 2,
                                                   width: barWidth, height: barHeight),
                               cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil))
        context.fillPath()
    }

    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    func draw(_ text: String, size: Double, weight: NSFont.Weight, alpha: Double, y: Double) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(cgColor: color(255, 255, 255, alpha))!,
        ]
        NSAttributedString(string: text, attributes: attributes)
            .draw(at: CGPoint(x: width * 0.38, y: y))
    }

    draw("Claude MCP Manager", size: 74, weight: .semibold, alpha: 1, y: height * 0.545)
    draw("Edit Claude Desktop's MCP servers", size: 38, weight: .regular, alpha: 0.86, y: height * 0.42)
    draw("without counting brackets.", size: 38, weight: .regular, alpha: 0.86, y: height * 0.335)

    NSGraphicsContext.restoreGraphicsState()
}

if variantArgument == "social" {
    let width = 1280.0, height = 640.0
    let context = CGContext(
        data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setAllowsAntialiasing(true)
    drawSocialCard(into: context, width: width, height: height)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    rep.size = NSSize(width: width, height: height)
    let url = URL(fileURLWithPath: outputPath)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote social preview to \(url.path)")
    exit(0)
}

let output = URL(fileURLWithPath: outputPath)
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let sizes: [(String, Double)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    write(size: pixels, to: output.appendingPathComponent("\(name).png"))
}
print("wrote \(variant.rawValue) at \(sizes.count) sizes")
