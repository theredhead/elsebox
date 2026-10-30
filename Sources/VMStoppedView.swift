import AppKit

@MainActor
final class VMStoppedView: NSView {
    private let bundle: VMBundle
    private let summary = NSTextField(labelWithString: "")
    private let displaySummary = NSTextField(labelWithString: "")
    private let startButton = NSButton(title: "Start", target: nil, action: nil)
    private let configureButton = NSButton(title: "Configure…", target: nil, action: nil)
    var onStart: (() -> Void)?
    var onConfigure: (() -> Void)?

    init(bundle: VMBundle) {
        self.bundle = bundle
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let artwork = GuestIconView(distribution: bundle.distribution)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            artwork.widthAnchor.constraint(equalToConstant: 110),
            artwork.heightAnchor.constraint(equalToConstant: 110),
        ])
        let title = NSTextField(labelWithString: bundle.name)
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        let system = NSTextField(labelWithString: bundle.preset.title)
        system.font = .systemFont(ofSize: 17)
        summary.font = .systemFont(ofSize: 15)
        displaySummary.textColor = .secondaryLabelColor
        startButton.target = self
        startButton.action = #selector(start)
        startButton.bezelStyle = .rounded
        configureButton.target = self
        configureButton.action = #selector(configure)
        configureButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [startButton, configureButton])
        buttons.spacing = 12
        let stack = NSStackView(views: [artwork, title, system, summary, displaySummary, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh(canStart: true, canConfigure: true)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refresh(canStart: Bool, canConfigure: Bool) {
        startButton.isEnabled = canStart
        configureButton.isEnabled = canConfigure
        guard let settings = try? bundle.resolvedSettings() else { return }
        let disk = VMDiskStore.disk(for: settings)
        let bytes = (try? disk.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        summary.stringValue =
            "\(settings.cpu) cores · \(settings.memory / 1_073_741_824) GiB RAM · \(bytes / 1_000_000_000) GB disk"
        displaySummary.stringValue =
            "ARM64 · \(settings.displayWidth ?? 1920) × \(settings.displayHeight ?? 1080)"
    }

    @objc private func start() { onStart?() }
    @objc private func configure() { onConfigure?() }
}

/// Compact vector marks keep stopped VMs identifiable without downloaded artwork.
@MainActor
private final class GuestIconView: NSView {
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
        let rect = bounds.insetBy(dx: 7, dy: 7)
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
