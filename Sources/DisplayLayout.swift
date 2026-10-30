import AppKit

/// Guest dimensions for the actual drawable viewport, preserving the selected width
/// when possible and keeping requests inside the supported preference bounds.
enum DisplayLayout {
    static func fittedSize(viewport: CGSize, preferredWidth: Int) -> CGSize? {
        guard viewport.width.isFinite, viewport.height.isFinite,
            viewport.width > 0, viewport.height > 0
        else { return nil }
        let ratio = viewport.width / viewport.height
        let lowerWidth = max(640.0, 480.0 * ratio)
        let upperWidth = min(7680.0, 4320.0 * ratio)
        guard lowerWidth <= upperWidth else { return nil }
        let width = min(max(Double(preferredWidth), lowerWidth), upperWidth).rounded()
        let height = (width / ratio).rounded()
        return CGSize(width: width, height: height)
    }
}

/// Borderless edge-to-edge presentation still needs keyboard and mouse focus.
@MainActor
final class VMWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
