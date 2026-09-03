import AppKit
import CoreGraphics
import Foundation

// Draws the app icon at every size macOS asks for. Generated rather than drawn by
// hand so it stays editable: change the numbers here, re-run make-icon.sh.
//
// The mark is a pair of braces around three server dots — the JSON config this app
// edits, and the list of servers inside it.

let canvas = 1024.0

/// macOS icon grid: the rounded body sits inside the canvas with a margin, so the
/// Dock has room for its shadow.
let bodyInset = 100.0
let cornerRadius = 185.4

func makeContext(size: Double) -> CGContext {
    let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    return context
}

func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
    CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

let deepIndigo = color(60, 54, 140)
let brightIndigo = color(120, 104, 232)
let amber = color(247, 178, 84)
let white = color(255, 255, 255)

func draw(into context: CGContext, size: Double) {
    let scale = size / canvas
    context.scaleBy(x: scale, y: scale)

    let body = CGRect(x: bodyInset, y: bodyInset,
                      width: canvas - bodyInset * 2,
                      height: canvas - bodyInset * 2)
    let shape = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // Background: a diagonal gradient, light at the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [brightIndigo, deepIndigo] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: body.minX, y: body.maxY),
        end: CGPoint(x: body.maxX, y: body.minY),
        options: []
    )

    // A soft highlight across the top, the way macOS icons catch light.
    let sheen = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [color(255, 255, 255, 0.20), color(255, 255, 255, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        sheen,
        start: CGPoint(x: body.midX, y: body.maxY),
        end: CGPoint(x: body.midX, y: body.midY),
        options: []
    )
    context.restoreGState()

    // The braces, set in the rounded system face so they match macOS chrome.
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics

    let braceSize = 470.0
    var braceFont = NSFont.systemFont(ofSize: braceSize, weight: .bold)
    if let rounded = braceFont.fontDescriptor.withDesign(.rounded) {
        braceFont = NSFont(descriptor: rounded, size: braceSize) ?? braceFont
    }

    func drawBrace(_ text: String, centeredAt centre: CGPoint) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: braceFont,
            .foregroundColor: NSColor(cgColor: white)!,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()
        string.draw(at: CGPoint(x: centre.x - bounds.width / 2, y: centre.y - bounds.height / 2))
    }

    let centreY = canvas / 2 - braceSize * 0.02
    drawBrace("{", centeredAt: CGPoint(x: canvas / 2 - 158, y: centreY))
    drawBrace("}", centeredAt: CGPoint(x: canvas / 2 + 158, y: centreY))

    NSGraphicsContext.restoreGraphicsState()

    // Three servers between the braces; the middle one is the selected row.
    let dotRadius = 38.0
    let spacing = 108.0
    for (index, fill) in [white, amber, white].enumerated() {
        let y = canvas / 2 + spacing - Double(index) * spacing
        context.setFillColor(fill)
        context.fillEllipse(in: CGRect(
            x: canvas / 2 - dotRadius,
            y: y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
    }
}

func write(size: Double, to url: URL) {
    let context = makeContext(size: size)
    draw(into: context, size: size)
    guard let image = context.makeImage() else { fatalError("could not render \(size)") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("could not encode") }
    try! data.write(to: url)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// The set macOS expects inside a .iconset.
let sizes: [(name: String, pixels: Double)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, pixels) in sizes {
    write(size: pixels, to: output.appendingPathComponent("\(name).png"))
}
print("wrote \(sizes.count) sizes to \(output.path)")
