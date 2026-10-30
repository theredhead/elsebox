import AppKit

/// Borderless edge-to-edge presentation still needs keyboard and mouse focus.
@MainActor
final class VMWindow: NSWindow {
    override var canBecomeKey: Bool { true }

    override var canBecomeMain: Bool { true }
}
