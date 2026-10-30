import AppKit

/// Owns named host-folder rows and their validation; an empty list explicitly disables sharing.
@MainActor
final class SharedFoldersPreferences: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
    private let folderList = SharedFolderListView()
    private var folderRows: [SharedFolderRow] = []

    init(settings: VMSettings) {
        super.init()
        let shared = view
        PreferenceForm.note("Name in guest", x: 20, y: 284, in: shared)
        PreferenceForm.note("Host folder", x: 165, y: 284, in: shared)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 63, width: 535, height: 214))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        folderList.frame = NSRect(x: 0, y: 0, width: 515, height: 214)
        scroll.documentView = folderList
        shared.addSubview(scroll)
        PreferenceForm.button(
            "Add Folders…", action: #selector(addFolders), target: self, x: 20, y: 26, in: shared)
        PreferenceForm.note(
            "Remove all entries to disable sharing. Changes apply on the next start.", y: 0, in: shared)
        let shares =
            settings.sharedFolders ?? [
                SharedFolder(
                    name: "Shared", path: VMDiskStore.directory.appendingPathComponent("Shared").path,
                    readOnly: false)
            ]
        for share in shares { addFolderRow(share) }
    }

    func apply(to result: inout VMSettings) throws {
        let shares = folderRows.map { $0.share }
        try VMDiskStore.validateShares(shares)
        result.sharedFolders = shares
    }

    @objc private func addFolders() {
        let panel = NSOpenPanel()
        panel.title = "Add Shared Folders"
        panel.message = "Select host folders to share with this virtual machine."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let base = url.lastPathComponent.isEmpty ? "Folder" : url.lastPathComponent
            var name = base
            var suffix = 2
            let names = Set(folderRows.map { $0.share.name.lowercased() })
            while names.contains(name.lowercased()) {
                name = "\(base) \(suffix)"
                suffix += 1
            }
            addFolderRow(SharedFolder(name: name, path: url.path, readOnly: false))
        }
    }

    private func addFolderRow(_ share: SharedFolder) {
        let row = SharedFolderRow(share: share)
        row.remove = { [weak self, weak row] in
            guard let self, let row else { return }
            self.folderRows.removeAll { $0 === row }
            row.removeFromSuperview()
            self.layoutFolderRows()
        }
        folderRows.append(row)
        folderList.addSubview(row)
        layoutFolderRows()
    }

    private func layoutFolderRows() {
        folderList.setFrameSize(NSSize(width: 515, height: max(214, folderRows.count * 44)))
        for (index, row) in folderRows.enumerated() {
            row.frame = NSRect(x: 0, y: index * 44, width: 515, height: 44)
        }
    }
}
