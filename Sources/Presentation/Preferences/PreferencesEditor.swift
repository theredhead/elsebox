import AppKit
import UniformTypeIdentifiers

@MainActor
final class PreferencesEditor: NSView {
    private var original: VMSettings
    private let bundle: VMBundle?
    private let cpu = NSPopUpButton()
    private let memory = NSPopUpButton()
    private let density = NSTextField()
    private let input = NSPopUpButton()
    private let startupMode = NSPopUpButton()
    private let remoteAddress = NSTextField()
    private let remoteUsername = NSTextField()
    private var isWindows: Bool { bundle?.distribution == .windows }
    private var protectsStartupDisk: Bool { isWindows && original.bootFromInstaller == false }
    private let audioOutput = NSButton(
        checkboxWithTitle: "Play guest audio through the host output", target: nil, action: nil)
    private let resolution: ResolutionPicker
    private let diskLabel = NSTextField(wrappingLabelWithString: "")
    private let capacityLabel = NSTextField(labelWithString: "")
    private let restoreLabel = NSTextField(wrappingLabelWithString: "")
    private var diskURL: URL
    private var restoreURL: URL?
    private var driverURL: URL?
    private let automaticDrivers = NSButton(
        checkboxWithTitle: "Use bundled Windows drivers", target: nil, action: nil)
    private let driverLabel = NSTextField(wrappingLabelWithString: "")
    private let bootInstaller = NSButton(checkboxWithTitle: "Boot installer ISO", target: nil, action: nil)
    private var usesEFI: Bool { return bundle?.distribution.usesEFI == true }
    private let folderList = SharedFolderListView()
    private var folderRows: [SharedFolderRow] = []

    init(
        settings: VMSettings, cpuLimits: ClosedRange<Int>, memoryLimits: ClosedRange<Int>,
        hostAspectRatio: Double, bundle: VMBundle? = nil
    ) {
        self.bundle = bundle
        original = settings
        driverURL = settings.driverMediaPath.map { URL(fileURLWithPath: $0) }
        diskURL = VMDiskStore.disk(for: settings)
        restoreURL =
            (bundle?.distribution.usesEFI == true
            ? settings.installationMediaPath : settings.restoreImagePath).map { URL(fileURLWithPath: $0) }
        resolution = ResolutionPicker(
            width: settings.displayWidth ?? 1920, height: settings.displayHeight ?? 1080,
            keepHostAspectRatio: settings.keepHostAspectRatio ?? false,
            hostAspectRatio: hostAspectRatio)
        super.init(frame: NSRect(x: 0, y: 0, width: 580, height: 410))
        let tabs = NSTabView(frame: bounds)
        tabs.autoresizingMask = [.width, .height]
        addSubview(tabs)
        let general = addTab("Hardware", to: tabs)
        for value in cpuLimits where bundle?.distribution != .windows || value >= 2 {
            cpu.addItem(withTitle: "\(value)")
            cpu.lastItem?.tag = value
        }
        cpu.selectItem(
            withTag: min(
                max(
                    settings.cpu,
                    max(
                        cpuLimits.lowerBound,
                        bundle?.distribution == .windows ? 2 : 1)), cpuLimits.upperBound))
        for value in memoryLimits where bundle?.distribution != .windows || value >= 4 {
            memory.addItem(withTitle: "\(value) GiB")
            memory.lastItem?.tag = value
        }
        let selectedMemory = Int((settings.memory + 1_073_741_823) / 1_073_741_824)
        memory.selectItem(
            withTag: min(
                max(
                    selectedMemory,
                    max(
                        memoryLimits.lowerBound,
                        bundle?.distribution == .windows ? 4 : 1)), memoryLimits.upperBound))
        field(cpu, label: "CPU cores:", y: 305, in: general)
        field(memory, label: "Memory:", y: 265, in: general)
        resolution.frame = NSRect(x: 20, y: 132, width: 360, height: 110)
        general.addSubview(resolution)
        density.stringValue = String(settings.pixelsPerInch ?? 72)
        density.setAccessibilityLabel("Display density in pixels per inch")
        field(density, label: "Display density (PPI):", y: 87, in: general)
        input.addItems(withTitles: ["USB mouse", "Mac trackpad"])
        input.selectItem(at: !usesEFI && settings.useMacTrackpad == true ? 1 : 0)
        input.isEnabled = !usesEFI
        density.isEnabled = !usesEFI
        field(input, label: "Pointer input:", y: 47, in: general)
        input.setFrameSize(NSSize(width: 320, height: 26))
        input.setAccessibilityLabel("Pointer input mode")

        let startup = addTab("Startup", to: tabs)
        startupMode.addItems(withTitles: ["Always open the display", "Always start headless"])
        startupMode.selectItem(at: settings.startHeadless == true ? 1 : 0)
        startupMode.setAccessibilityLabel("Default startup mode")
        field(startupMode, label: "Default startup mode:", y: 285, in: startup)
        startupMode.setFrameSize(NSSize(width: 280, height: 26))

        if !isWindows {
            let audio = addTab("Audio", to: tabs)
            audioOutput.state = settings.audioOutputEnabled != false ? .on : .off
            audioOutput.frame = NSRect(x: 20, y: 285, width: 510, height: 26)
            audio.addSubview(audioOutput)
            note("Uses the host’s default output device. Applies on the next VM start.", y: 240, in: audio)
        }
        if isWindows {
            resolution.isHidden = true
            density.isHidden = true
            input.isHidden = true
            for view in general.subviews where view is NSTextField && view.frame.minY < 240 {
                view.isHidden = true
            }
            let remote = addTab("Remote Desktop", to: tabs)
            remoteAddress.stringValue = settings.remoteDesktopAddress ?? ""
            remoteUsername.stringValue = settings.remoteDesktopUsername ?? ""
            field(remoteAddress, label: "Address:", y: 285, in: remote)
            field(remoteUsername, label: "Username:", y: 240, in: remote)
            button("Connect…", action: #selector(connectRemoteDesktop), x: 20, y: 175, in: remote)
        }
        let storage = addTab("Storage & Installation", to: tabs)
        heading("Startup disk", y: 277, in: storage)
        diskLabel.frame = NSRect(x: 20, y: 217, width: 510, height: 48)
        diskLabel.isSelectable = true
        storage.addSubview(diskLabel)
        capacityLabel.frame = NSRect(x: 20, y: 191, width: 510, height: 22)
        storage.addSubview(capacityLabel)
        button("Choose Disk…", action: #selector(chooseDisk), x: 20, y: 151, in: storage)
        button("Create Disk…", action: #selector(createDisk), x: 180, y: 151, in: storage)
        heading(usesEFI ? "Installer ISO" : "macOS restore image", y: 112, in: storage)
        restoreLabel.frame = NSRect(x: 20, y: 65, width: 510, height: 42)
        restoreLabel.isSelectable = true
        storage.addSubview(restoreLabel)
        button(
            usesEFI ? "Choose ISO…" : "Choose IPSW…", action: #selector(chooseRestore), x: 20, y: 28,
            in: storage)
        let automatic = button(
            "Use Automatic", action: #selector(automaticRestore), x: 180, y: 28,
            in: storage)
        automatic.isEnabled = bundle?.distribution.hasAutomaticInstaller ?? true
        if usesEFI {
            bootInstaller.state = settings.bootFromInstaller == false ? .off : .on
            bootInstaller.frame = NSRect(x: 20, y: 0, width: 250, height: 24)
            storage.addSubview(bootInstaller)
        }
        if isWindows && !protectsStartupDisk {
            let drivers = addTab("Windows Drivers", to: tabs)
            heading("Optional ARM64 driver ISO", y: 277, in: drivers)
            driverLabel.frame = NSRect(x: 20, y: 190, width: 510, height: 70)
            drivers.addSubview(driverLabel)
            button("Choose ISO…", action: #selector(chooseDrivers), x: 20, y: 145, in: drivers)
            button("Remove", action: #selector(removeDrivers), x: 180, y: 145, in: drivers)
            automaticDrivers.state = settings.automaticWindowsDrivers == true ? .on : .off
            automaticDrivers.frame = NSRect(x: 20, y: 100, width: 480, height: 24)
            automaticDrivers.target = self
            automaticDrivers.action = #selector(driverModeChanged)
            drivers.addSubview(automaticDrivers)
            updateDriverLabel()
        }
        if protectsStartupDisk {
            for control in storage.subviews.compactMap({ $0 as? NSControl }) {
                if !(control is NSTextField) { control.isHidden = true }
            }
            restoreLabel.isHidden = true
            for label in storage.subviews.compactMap({ $0 as? NSTextField }) where label.frame.minY == 112 {
                label.isHidden = true
            }
        }
        updateStorageLabels()

        if bundle?.distribution == .windows { return }
        let shared = addTab("Shared Folders", to: tabs)
        note("Name in guest", x: 20, y: 284, in: shared)
        note("Host folder", x: 165, y: 284, in: shared)
        let scroll = NSScrollView(frame: NSRect(x: 16, y: 63, width: 535, height: 214))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        folderList.frame = NSRect(x: 0, y: 0, width: 515, height: 214)
        scroll.documentView = folderList
        shared.addSubview(scroll)
        button("Add Folders…", action: #selector(addFolders), x: 20, y: 26, in: shared)
        note("Remove all entries to disable sharing. Changes apply on the next start.", y: 0, in: shared)
        let shares =
            settings.sharedFolders ?? [
                SharedFolder(
                    name: "Shared", path: VMDiskStore.directory.appendingPathComponent("Shared").path,
                    readOnly: false)
            ]
        for share in shares { addFolderRow(share) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func settings() throws -> VMSettings {
        guard let ppi = Int(density.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
            (36...300).contains(ppi)
        else {
            throw settingsError("Display density must be a whole number between 36 and 300 PPI.")
        }
        try VMDiskStore.validate(diskURL)
        let shares =
            bundle?.distribution == .windows ? (original.sharedFolders ?? []) : folderRows.map { $0.share }
        try VMDiskStore.validateShares(shares)
        if let selected = restoreURL, !FileManager.default.isReadableFile(atPath: selected.path) {
            let shared = bundle?.mediaCache.reference(for: selected) != nil
            let installed = FileManager.default.fileExists(
                atPath: VMDiskStore.metadata(for: diskURL).appendingPathComponent("Installed").path)
            if (usesEFI && bootInstaller.state == .off) || (!usesEFI && installed)
                || (shared && bundle?.distribution.hasAutomaticInstaller == true)
            {
                restoreURL = nil
            } else {
                throw settingsError("The selected installation media is unavailable.")
            }
        }
        if usesEFI && bootInstaller.state == .on && restoreURL == nil
            && bundle?.distribution.hasAutomaticInstaller == false
        {
            throw settingsError("Select an ARM64 installer ISO.")
        }
        var result = original
        result.startHeadless = startupMode.indexOfSelectedItem == 1
        result.cpu = cpu.selectedTag()
        result.memory = UInt64(memory.selectedTag()) * 1_073_741_824
        result.displayWidth = resolution.selectedResolution.width
        result.displayHeight = resolution.selectedResolution.height
        result.keepHostAspectRatio = resolution.keepsHostAspectRatio
        result.pixelsPerInch = ppi
        result.useMacTrackpad = input.indexOfSelectedItem == 1
        result.audioOutputEnabled = isWindows ? original.audioOutputEnabled : audioOutput.state == .on
        result.remoteDesktopAddress = remoteAddress.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
        result.remoteDesktopUsername = remoteUsername.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
        result.diskPath = diskURL.path
        if usesEFI {
            result.installationMediaPath = restoreURL?.path
            result.bootFromInstaller = bootInstaller.state == .on
        } else {
            result.restoreImagePath = restoreURL?.path
        }
        result.driverMediaPath = driverURL?.path
        result.automaticWindowsDrivers = automaticDrivers.state == .on
        result.sharedFolders = shares
        if isWindows {
            result.displayWidth = 1024
            result.displayHeight = 768
            result.keepHostAspectRatio = false
            result.pixelsPerInch = 72
            result.useMacTrackpad = false
        }
        if protectsStartupDisk {
            result.diskPath = original.diskPath
            result.installationMediaPath = original.installationMediaPath
            result.bootFromInstaller = false
            result.driverMediaPath = original.driverMediaPath
            result.automaticWindowsDrivers = original.automaticWindowsDrivers
        }
        return result
    }

    @objc private func connectRemoteDesktop() {
        do {
            let address = remoteAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = remoteUsername.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, !address.contains(where: { $0.isWhitespace || $0.isNewline }),
                !username.contains(where: { $0.isNewline })
            else { throw settingsError("Enter a Remote Desktop address.") }
            let text = """
                full address:s:\(address)
                username:s:\(username)
                audiomode:i:0
                audiocapturemode:i:0
                redirectclipboard:i:0
                authentication level:i:2
                prompt for credentials:i:1
                """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "VirtualMac-\(UUID().uuidString).rdp")
            try Data(text.utf8).write(to: url, options: .atomic)
            guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
                throw settingsError("Install Microsoft Windows App to open Remote Desktop connections.")
            }
            NSWorkspace.shared.open(url)
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func chooseDrivers() {
        let panel = NSOpenPanel()
        panel.title = "Choose Windows ARM64 VirtIO Drivers (.iso)"
        panel.message =
            "Select a VirtIO driver ISO containing Windows ARM64 drivers (for example, virtio-win-0.1.302.iso). The Windows installer ISO belongs under Storage & Installation."
        panel.prompt = "Choose Drivers"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .data]
        guard panel.runModal() == .OK else { return }
        automaticDrivers.state = .off
        driverURL = panel.url
        updateDriverLabel()
    }

    @objc private func removeDrivers() {
        automaticDrivers.state = .off
        driverURL = nil
        updateDriverLabel()
    }

    @objc private func driverModeChanged() {
        if automaticDrivers.state == .on { driverURL = nil }
        updateDriverLabel()
    }

    private func updateDriverLabel() {
        driverLabel.stringValue =
            driverURL?.path
            ?? (automaticDrivers.state == .on ? "VirtIO-Win 0.1.302 · included with the app" : "None")
    }

    private func addTab(_ title: String, to tabs: NSTabView) -> NSView {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
        item.view = view
        tabs.addTabViewItem(item)
        return view
    }

    private func field(_ control: NSControl, label: String, y: CGFloat, in view: NSView) {
        let text = NSTextField(labelWithString: label)
        text.frame = NSRect(x: 20, y: y + 3, width: 175, height: 22)
        control.frame = NSRect(x: 205, y: y, width: 160, height: 26)
        view.addSubview(text)
        view.addSubview(control)
    }

    private func heading(_ title: String, y: CGFloat, in view: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.frame = NSRect(x: 20, y: y, width: 500, height: 22)
        view.addSubview(label)
    }

    private func note(_ text: String, x: CGFloat = 20, y: CGFloat, in view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: y, width: 530 - x, height: 20)
        view.addSubview(label)
    }

    @discardableResult
    private func button(_ title: String, action: Selector, x: CGFloat, y: CGFloat, in view: NSView)
        -> NSButton
    {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: x, y: y, width: 150, height: 30)
        view.addSubview(button)
        return button
    }

    private func updateStorageLabels() {
        diskLabel.stringValue = diskURL.path
        let size = (try? diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        capacityLabel.stringValue = String(format: "%.1f GB capacity", Double(size) / 1_000_000_000)
        restoreLabel.stringValue =
            restoreURL?.path
            ?? (usesEFI && bundle?.distribution.hasAutomaticInstaller == false ? "Local ISO" : "Automatic")
    }

    @objc private func chooseDisk() {
        let panel = NSOpenPanel()
        panel.title = "Choose a VirtualMac Startup Disk"
        panel.message =
            "Choose a stopped VirtualMac disk with its identity files. Save imports a copy into this .asvm bundle."
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
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
            diskURL = selectedDisk
            updateStorageLabels()
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func createDisk() {
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
        guard prompt.runModal() == .alertFirstButtonReturn else { return }
        guard let size = Int(capacity.stringValue), (8...4096).contains(size) else {
            NSAlert(error: settingsError("Enter a whole number between 8 and 4096 GB.")).runModal()
            return
        }
        do {
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
                guard panel.runModal() == .OK, let url = panel.url else { return }
                target = url
            }
            try VMDiskStore.create(at: target, capacityGB: size)
            diskURL = target
            updateStorageLabels()
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func chooseRestore() {
        let panel = NSOpenPanel()
        let distribution = bundle?.distribution ?? .macOS
        panel.title = distribution.installerSelectionTitle
        panel.message = distribution.installerSelectionMessage
        panel.prompt = "Choose Installer"
        panel.allowedContentTypes = [UTType(filenameExtension: usesEFI ? "iso" : "ipsw") ?? .data]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        restoreURL = panel.url
        if usesEFI { bootInstaller.state = .on }
        updateStorageLabels()
    }

    @objc private func automaticRestore() {
        restoreURL = nil
        if usesEFI { bootInstaller.state = .on }
        updateStorageLabels()
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
