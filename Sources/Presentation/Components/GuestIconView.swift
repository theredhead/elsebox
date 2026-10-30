import AppKit

/// Compact vector marks keep stopped VMs identifiable without downloaded artwork.
@MainActor
final class GuestIconView: NSView {
    private let distribution: GuestDistribution

    init(distribution: GuestDistribution) {
        self.distribution = distribution
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(distribution.title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let transform = NSAffineTransform()
        transform.scaleX(by: bounds.width / 110, yBy: bounds.height / 110)
        transform.concat()
        let rect = NSRect(x: 7, y: 7, width: 96, height: 96)
        switch distribution {
        case .macOS:
            NSImage(systemSymbolName: "apple.logo", accessibilityDescription: "macOS")?
                .withSymbolConfiguration(.init(paletteColors: [.labelColor]))?.draw(in: rect)
        case .debian:
            NSColor.systemPink.setStroke()
            let path = NSBezierPath()
            for step in 0...180 {
                let theta = Double(step) / 180 * 4.5 * Double.pi
                let radius = 2 + Double(step) / 180 * 40
                let point = NSPoint(x: 55 + cos(theta) * radius, y: 55 + sin(theta) * radius)
                if step == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.lineWidth = 5
            path.lineCapStyle = .round
            path.stroke()
        case .ubuntu:
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: rect).fill()
            NSColor.white.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 29, y: 29, width: 52, height: 52))
            ring.lineWidth = 7
            ring.stroke()
            NSColor.white.setFill()
            for angle in [0.0, 120.0, 240.0] {
                let theta = angle / 180 * Double.pi
                NSBezierPath(
                    ovalIn: NSRect(
                        x: 55 + cos(theta) * 36 - 6, y: 55 + sin(theta) * 36 - 6, width: 12, height: 12)
                ).fill()
            }
        case .fedora:
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 86, weight: .semibold), .foregroundColor: NSColor.white,
            ]
            ("f" as NSString).draw(at: NSPoint(x: 36, y: 2), withAttributes: attributes)
        case .arch:
            NSColor.systemCyan.setFill()
            let triangle = NSBezierPath()
            triangle.move(to: NSPoint(x: 55, y: 103))
            triangle.line(to: NSPoint(x: 8, y: 8))
            triangle.line(to: NSPoint(x: 55, y: 30))
            triangle.line(to: NSPoint(x: 102, y: 8))
            triangle.close()
            triangle.fill()
        case .windows:
            NSColor.systemBlue.setFill()
            for x in [12.0, 58.0] {
                for y in [12.0, 58.0] {
                    NSBezierPath(rect: NSRect(x: x, y: y, width: 40, height: 40)).fill()
                }
            }
        case .customLinux:
            NSImage(systemSymbolName: "terminal", accessibilityDescription: "Linux")?.withSymbolConfiguration(
                .init(paletteColors: [.labelColor]))?.draw(in: rect)
        }
    }
}
