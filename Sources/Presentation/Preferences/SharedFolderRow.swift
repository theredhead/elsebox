import AppKit

/// Provides top-origin coordinates for the preference page’s folder rows.
final class SharedFolderListView: NSView {
    override var isFlipped: Bool { true }
}

/// Owns one shared-folder name/read-only editor and its remove request, without saving or mounting the share.
@MainActor
final class SharedFolderRow: NSView {
    private let name: NSTextField
    private let path: String
    private let readOnly: NSButton
    var remove: (() -> Void)?

    var share: SharedFolder {
        SharedFolder(
            name: name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), path: path,
            readOnly: readOnly.state == .on)
    }

    init(share: SharedFolder) {
        name = NSTextField(string: share.name)
        path = share.path
        readOnly = NSButton(checkboxWithTitle: "Read only", target: nil, action: nil)
        super.init(frame: .zero)
        name.frame = NSRect(x: 6, y: 10, width: 132, height: 24)
        name.setAccessibilityLabel("Shared folder name")
        let location = NSTextField(labelWithString: share.path)
        location.frame = NSRect(x: 146, y: 10, width: 220, height: 24)
        location.lineBreakMode = .byTruncatingMiddle
        location.toolTip = share.path
        readOnly.frame = NSRect(x: 369, y: 10, width: 91, height: 24)
        readOnly.state = share.readOnly ? .on : .off
        let removeButton = NSButton(title: "−", target: self, action: #selector(removeRow))
        removeButton.bezelStyle = .rounded
        removeButton.frame = NSRect(x: 468, y: 7, width: 34, height: 30)
        removeButton.setAccessibilityLabel("Remove \(share.name)")
        for view in [name, location, readOnly, removeButton] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func removeRow() { remove?() }
}
