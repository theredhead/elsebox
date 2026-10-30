import AppKit

/// Renders per-VM progress without a text label; details and cancel/retry actions remain in native affordances.
@MainActor
final class VMDownloadProgressView: NSProgressIndicator {
    private let menuItem = NSMenuItem()
    var onAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        style = .bar
        controlSize = .small
        minValue = 0
        maxValue = 1
        isHidden = true
        let contextMenu = NSMenu()
        menuItem.target = self
        menuItem.action = #selector(downloadAction)
        contextMenu.addItem(menuItem)
        menu = contextMenu
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ state: InstallerPreparationState?) {
        let visible = state.map { $0.active || $0.failed } ?? false
        isHidden = !visible
        guard let state, visible else {
            stopAnimation(nil)
            return
        }
        isIndeterminate = state.active && state.fraction == nil
        doubleValue = state.fraction ?? 0
        if isIndeterminate {
            startAnimation(nil)
        } else {
            stopAnimation(nil)
        }

        let description = state.fraction.map { "\(state.message) \(Int($0 * 100))%" } ?? state.message
        toolTip = description
        setAccessibilityLabel(description)
        menuItem.title = state.active ? "Cancel Download" : "Retry Download"
    }

    @objc private func downloadAction() { onAction?() }
}
