import AppKit

/// Owns removable-media rows and dispatches eject requests using the currently displayed identifiers.
@MainActor
final class VMRemovableMediaList: NSObject {
    private let list = VMDetailList(title: "Removable Media", symbol: "externaldrive")

    var view: NSView { list.view }

    private var mediaSignature = ""
    private var mediaIDs: [String] = []
    var onEjectMedia: ((String) -> Void)?

    func update(_ media: [VMRemovableMedium]) {
        let signature = media.map { "\($0.id)-\($0.name)-\($0.readOnly)-\($0.canEject)-\($0.isInstaller)" }
            .joined(separator: "|")
        guard signature != mediaSignature || list.isEmpty else { return }
        mediaSignature = signature
        list.clear()
        mediaIDs = media.map { $0.id }
        if media.isEmpty { list.addRow(title: "None connected") }
        for (index, item) in media.enumerated() {
            let button = VMDetailList.actionButton(
                symbol: "eject", label: "Eject \(item.name)", target: self, action: #selector(ejectMedium(_:))
            )
            button.tag = index
            button.isEnabled = item.canEject
            list.addRow(
                title: item.name,
                subtitle:
                    "\(item.isInstaller ? "Installer · " : "")\(item.readOnly ? "Read only" : "Read/write")",
                button: button)
        }
    }

    @objc private func ejectMedium(_ sender: NSButton) {
        guard mediaIDs.indices.contains(sender.tag) else { return }
        onEjectMedia?(mediaIDs[sender.tag])
    }
}
