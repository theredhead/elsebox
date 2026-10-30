import AppKit
import QuartzCore

/// Circular control whose power glyph, rather than the button surface, breathes when on.
@MainActor
final class VMDetailPowerButton: NSButton {
    private let glyph = VMDetailPowerGlyph()
    private var appearanceState: [Bool] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = ""
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        glyph.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.wantsLayer = true
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 44),
            heightAnchor.constraint(equalToConstant: 44),
            glyph.widthAnchor.constraint(equalToConstant: 20),
            glyph.heightAnchor.constraint(equalToConstant: 22),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setPoweredOn(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPoweredOn(_ poweredOn: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let state = [poweredOn, isEnabled, reduceMotion]
        guard state != appearanceState else { return }
        appearanceState = state
        glyph.layer?.removeAnimation(forKey: "breathing")
        glyph.contentTintColor = poweredOn ? .systemGreen : .labelColor
        glyph.alphaValue = isEnabled ? 1 : 0.35
        glyph.layer?.shadowColor = NSColor.systemGreen.cgColor
        glyph.layer?.shadowOffset = .zero
        glyph.layer?.shadowRadius = 6
        glyph.layer?.shadowOpacity = poweredOn ? 0.65 : 0
        guard poweredOn, !reduceMotion else { return }

        let brightness = CABasicAnimation(keyPath: "opacity")
        brightness.fromValue = 0.45
        brightness.toValue = 1
        let glow = CABasicAnimation(keyPath: "shadowOpacity")
        glow.fromValue = 0.15
        glow.toValue = 0.85
        let breathing = CAAnimationGroup()
        breathing.animations = [brightness, glow]
        breathing.duration = 1.8
        breathing.autoreverses = true
        breathing.repeatCount = .infinity
        breathing.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glyph.layer?.add(breathing, forKey: "breathing")
    }
}

/// Keeps the power symbol display-only so all mouse and keyboard interaction belongs to its button.
@MainActor
private final class VMDetailPowerGlyph: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
