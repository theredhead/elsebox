import AppKit

// Run from the project root to regenerate the multi-resolution Finder/Dock icon.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let artwork = NSImage(contentsOf: root.appendingPathComponent("Resources/Artwork/AppIcon.png"))!

func smallIcon() {
    for (index, rect) in [
        NSRect(x: 1, y: 10, width: 19, height: 19),
        NSRect(x: 12, y: 9, width: 19, height: 19),
        NSRect(x: 7, y: 2, width: 19, height: 20),
    ].enumerated() {
        NSColor.white.setFill()
        NSColor.black.setStroke()
        let window = NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5)
        window.lineWidth = 1
        window.fill()
        window.stroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.minX, y: rect.maxY - 4))
        line.line(to: NSPoint(x: rect.maxX, y: rect.maxY - 4))
        line.stroke()
        let mark = NSRect(x: rect.minX + 6, y: rect.minY + 4, width: 8, height: 8)
        if index == 0 {
            NSImage(systemSymbolName: "apple.logo", accessibilityDescription: nil)?.draw(in: mark)
        } else if index == 1 {
            NSColor.black.setFill()
            for x in 0..<2 {
                for y in 0..<2 {
                    NSRect(
                        x: mark.minX + CGFloat(x) * 4.5, y: mark.minY + CGFloat(y) * 4.5,
                        width: 3.5, height: 3.5
                    ).fill()
                }
            }
        } else {
            let ring = NSBezierPath(ovalIn: mark.insetBy(dx: 1, dy: 1))
            ring.lineWidth = 2
            ring.stroke()
            for angle in [90.0, 210.0, 330.0] {
                let radians = angle * .pi / 180
                let dot = NSRect(
                    x: mark.midX + cos(radians) * 3.5 - 1.2,
                    y: mark.midY + sin(radians) * 3.5 - 1.2, width: 2.4, height: 2.4)
                NSColor.white.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: -0.6, dy: -0.6)).fill()
                NSColor.black.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}

let entries = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
for (size, scale) in entries {
    let pixels = size * scale
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    if pixels < 64 {
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 32)
        transform.concat()
        smallIcon()
    } else {
        let factor = CGFloat(pixels) / max(artwork.size.width, artwork.size.height)
        let width = artwork.size.width * factor
        let height = artwork.size.height * factor
        artwork.draw(
            in: NSRect(
                x: (CGFloat(pixels) - width) / 2,
                y: (CGFloat(pixels) - height) / 2, width: width, height: height))
    }
    NSGraphicsContext.restoreGraphicsState()
    let suffix = scale == 2 ? "@2x" : ""
    let file = output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png")
    try bitmap.representation(using: .png, properties: [:])!.write(to: file)
}
