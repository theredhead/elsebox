import AppKit

/// Chooses or creates a managed startup disk without mutating an open preference page.
@MainActor
enum StartupDiskPicker {
    static func choose(usesEFI: Bool) throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a ElseBox Startup Disk"
        panel.message =
            "Choose a stopped ElseBox disk with its identity files. Save imports a copy into this .asvm bundle."
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        let selectedDisk: URL
        if url.pathExtension.lowercased() == "asvm" {
            let source = try VMBundle.open(url)
            guard source.distribution.usesEFI == usesEFI else {
                throw settingsError("The startup disk belongs to a different guest family.")
            }
            selectedDisk = VMDiskStore.disk(for: try source.resolvedSettings())
        } else {
            selectedDisk = url
        }
        try VMDiskStore.validate(selectedDisk)
        return selectedDisk
    }

    static func create(bundle: VMBundle?) throws -> URL? {
        let prompt = NSAlert()
        prompt.messageText = "Create a New Startup Disk"
        prompt.informativeText =
            "Capacity in GB (8–4096). Creates an empty sparse RAW image and separate VM identity. Existing disks are never resized or overwritten. The new file remains even if you cancel Preferences."
        let capacity = NSTextField(string: "50")
        capacity.frame = NSRect(x: 0, y: 0, width: 180, height: 26)
        capacity.setAccessibilityLabel("New disk capacity in GB")
        prompt.accessoryView = capacity
        prompt.addButton(withTitle: bundle == nil ? "Choose Location…" : "Create in Bundle")
        prompt.addButton(withTitle: "Cancel")
        guard prompt.runModal() == .alertFirstButtonReturn else { return nil }
        guard let size = Int(capacity.stringValue), (8...4096).contains(size) else {
            NSAlert(error: settingsError("Enter a whole number between 8 and 4096 GB.")).runModal()
            return nil
        }

        let target: URL
        if let bundle {
            target = bundle.url.appendingPathComponent("Disks/\(UUID().uuidString)/Disk.img")
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } else {
            let panel = NSSavePanel()
            panel.title = "Create Startup Disk"
            panel.prompt = "Create"
            panel.nameFieldStringValue = "New Mac.img"
            panel.directoryURL = VMDiskStore.directory
            guard panel.runModal() == .OK, let url = panel.url else { return nil }
            target = url
        }
        try VMDiskStore.create(at: target, capacityGB: size)
        return target
    }
}
