import AppKit
import Virtualization

/// Keeps the USB scrolling workaround while normalizing secondary-button input.
@MainActor
final class VMInputView: VZVirtualMachineView {
    // Set from the running VM's configuration, not from subsequently edited preferences.
    var canMountImages: (() -> Bool)?
    var mountImages: (([URL]) -> Bool)?
    var usesUSBMouse = true
    var viewportDidChange: (() -> Void)?
    private var previousViewportSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    private func droppedURLs(_ sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { ["iso", "img", "raw"].contains($0.pathExtension.lowercased()) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canMountImages?() == true && !droppedURLs(sender).isEmpty ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canMountImages?() == true && !droppedURLs(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        mountImages?(droppedURLs(sender)) ?? false
    }

    override func layout() {
        super.layout()
        guard bounds.size != previousViewportSize else { return }
        previousViewportSize = bounds.size
        viewportDidChange?()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.rightMouseDown(with: usesUSBMouse ? Self.usbSecondaryClick(from: event) : event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        super.rightMouseDragged(with: usesUSBMouse ? Self.usbSecondaryClick(from: event) : event)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: usesUSBMouse ? Self.usbSecondaryClick(from: event) : event)
    }

    /// Use the original Quartz event so window coordinates, modifiers, timestamps,
    /// click counts and pressure survive. Only button/type/subtype are normalized.
    /// Events are delivered directly to the VM view; nothing is posted system-wide.
    static func usbSecondaryClick(from event: NSEvent) -> NSEvent {
        let type: CGEventType
        switch event.type {
        case .rightMouseDown: type = .rightMouseDown
        case .rightMouseDragged: type = .rightMouseDragged
        case .rightMouseUp: type = .rightMouseUp
        default: return event
        }
        guard let quartz = event.cgEvent?.copy() else { return event }
        quartz.type = type
        quartz.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.right.rawValue))
        quartz.setIntegerValueField(
            .mouseEventSubtype, value: Int64(CGEventMouseSubtype.defaultType.rawValue))
        return NSEvent(cgEvent: quartz) ?? event
    }
}
