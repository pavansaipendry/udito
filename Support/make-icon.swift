// Renders the Ears app icon at every required size into an .iconset folder.
// Usage: swift Support/make-icon.swift <output.iconset>
// Then:  iconutil -c icns <output.iconset> -o Support/AppIcon.icns

import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func drawIcon(canvas: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: canvas, height: canvas))
    image.lockFocus()
    defer { image.unlockFocus() }
    NSGraphicsContext.current?.imageInterpolation = .high

    // macOS icon grid: ~9% margin, ~22.5% corner radius.
    let margin = canvas * 0.09
    let rect = NSRect(x: margin, y: margin, width: canvas - margin * 2, height: canvas - margin * 2)
    let radius = rect.width * 0.225
    let plate = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.16, alpha: 1),
        NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.04, alpha: 1),
    ])!.draw(in: plate, angle: -90)

    NSColor.white.withAlphaComponent(0.10).setStroke()
    plate.lineWidth = max(canvas * 0.006, 0.5)
    plate.stroke()

    // White ear + waveform glyph.
    if let symbol = NSImage(systemSymbolName: "ear.badge.waveform", accessibilityDescription: nil),
       let configured = symbol.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: canvas * 0.5, weight: .medium)
       ) {
        let tinted = NSImage(size: configured.size)
        tinted.lockFocus()
        configured.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSColor.white.set()
        NSRect(origin: .zero, size: configured.size).fill(using: .sourceAtop)
        tinted.unlockFocus()

        let glyph = tinted.size
        let scale = (rect.width * 0.60) / max(glyph.width, glyph.height)
        let width = glyph.width * scale
        let height = glyph.height * scale
        tinted.draw(in: NSRect(
            x: rect.midX - width / 2,
            y: rect.midY - height / 2,
            width: width,
            height: height
        ))
    }
    return image
}

func savePNG(canvas: Int, name: String) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fatalError("bitmap rep failed") }
    rep.size = NSSize(width: canvas, height: canvas)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(canvas: CGFloat(canvas)).draw(
        in: NSRect(x: 0, y: 0, width: canvas, height: canvas),
        from: .zero, operation: .copy, fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png encode failed") }
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    savePNG(canvas: size, name: name)
}
print("iconset written to \(outDir)")
