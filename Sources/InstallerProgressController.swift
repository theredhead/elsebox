import AppKit

@MainActor
final class InstallerProgressController: NSObject {
    private let window: NSPanel
    private let label = NSTextField(labelWithString: "Preparing installer…")
    private let progress = NSProgressIndicator()
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var onCancel: (() -> Void)?

    init(name: String) {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 140), styleMask: [.titled],
            backing: .buffered, defer: false)
        super.init()
        window.title = name
        window.isReleasedWhenClosed = false
        window.level = .floating
        label.frame = NSRect(x: 20, y: 90, width: 390, height: 24)
        progress.frame = NSRect(x: 20, y: 62, width: 390, height: 18)
        progress.style = .bar
        progress.isIndeterminate = true
        progress.minValue = 0
        progress.maxValue = 1
        progress.startAnimation(nil)
        cancelButton.frame = NSRect(x: 310, y: 15, width: 100, height: 30)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(progress)
        window.contentView?.addSubview(cancelButton)
        window.center()
    }

    func show() { window.makeKeyAndOrderFront(nil) }
    func close() { window.close() }

    func update(_ message: String, fraction: Double?) {
        label.stringValue = fraction.map { "\(message) \(Int($0 * 100))%" } ?? message
        progress.isIndeterminate = fraction == nil
        if let fraction { progress.doubleValue = fraction } else { progress.startAnimation(nil) }
    }

    func beginSaving() {
        cancelButton.isEnabled = false
        update("Saving…", fraction: nil)
    }

    @objc private func cancel() {
        cancelButton.isEnabled = false
        label.stringValue = "Cancelling…"
        onCancel?()
    }
}
