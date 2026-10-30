import AppKit
import Virtualization

/// A second display surface with no guest input or automatic display resizing.
@MainActor
final class VMDetailPreview: VZVirtualMachineView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
