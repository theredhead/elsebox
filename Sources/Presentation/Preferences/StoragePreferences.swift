import AppKit
import UniformTypeIdentifiers

/// Owns disk/media selection and protects a successfully installed Windows startup configuration.
@MainActor
final class StoragePreferences: NSObject {
    let storageView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
    let driverView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
    private let bundle: VMBundle?
    private let original: VMSettings
    private let diskLabel = NSTextField(wrappingLabelWithString: "")
    private let capacityLabel = NSTextField(labelWithString: "")
    private let restoreLabel = NSTextField(wrappingLabelWithString: "")
    private let driverLabel = NSTextField(wrappingLabelWithString: "")
    private let automaticDrivers = NSButton(
        checkboxWithTitle: "Use bundled Windows drivers", target: nil, action: nil)
    private let bootInstaller = NSButton(checkboxWithTitle: "Boot installer ISO", target: nil, action: nil)
    private var diskURL: URL
    private var restoreURL: URL?
    private var driverURL: URL?

    private var usesEFI: Bool { bundle?.distribution.usesEFI == true }

    private var isWindows: Bool { bundle?.distribution == .windows }

    var protectsStartupDisk: Bool { isWindows && original.bootFromInstaller == false }

    init(settings: VMSettings, bundle: VMBundle?) {
        self.bundle = bundle
        original = settings
        diskURL = VMDiskStore.disk(for: settings)
        restoreURL =
            (bundle?.distribution.usesEFI == true
            ? settings.installationMediaPath : settings.restoreImagePath)
            .map { URL(fileURLWithPath: $0) }
        driverURL = settings.driverMediaPath.map { URL(fileURLWithPath: $0) }
        super.init()
        let storage = storageView
        PreferenceForm.heading("Startup disk", y: 277, in: storage)
        diskLabel.frame = NSRect(x: 20, y: 217, width: 510, height: 48)
        diskLabel.isSelectable = true
        storage.addSubview(diskLabel)
        capacityLabel.frame = NSRect(x: 20, y: 191, width: 510, height: 22)
        storage.addSubview(capacityLabel)
        PreferenceForm.button(
            "Choose Disk…", action: #selector(chooseDisk), target: self, x: 20, y: 151, in: storage)
        PreferenceForm.button(
            "Create Disk…", action: #selector(createDisk), target: self, x: 180, y: 151, in: storage)
        PreferenceForm.heading(usesEFI ? "Installer ISO" : "macOS restore image", y: 112, in: storage)
        restoreLabel.frame = NSRect(x: 20, y: 65, width: 510, height: 42)
        restoreLabel.isSelectable = true
        storage.addSubview(restoreLabel)
        PreferenceForm.button(
            usesEFI ? "Choose ISO…" : "Choose IPSW…", action: #selector(chooseRestore), target: self, x: 20,
            y: 28,
            in: storage)
        let automatic = PreferenceForm.button(
            "Use Automatic", action: #selector(automaticRestore), target: self, x: 180, y: 28,
            in: storage)
        automatic.isEnabled = bundle?.distribution.hasAutomaticInstaller ?? true
        if usesEFI {
            bootInstaller.state = settings.bootFromInstaller == false ? .off : .on
            bootInstaller.frame = NSRect(x: 20, y: 0, width: 250, height: 24)
            storage.addSubview(bootInstaller)
        }
        if isWindows && !protectsStartupDisk {
            let drivers = driverView
            PreferenceForm.heading("Optional ARM64 driver ISO", y: 277, in: drivers)
            driverLabel.frame = NSRect(x: 20, y: 190, width: 510, height: 70)
            drivers.addSubview(driverLabel)
            PreferenceForm.button(
                "Choose ISO…", action: #selector(chooseDrivers), target: self, x: 20, y: 145, in: drivers)
            PreferenceForm.button(
                "Remove", action: #selector(removeDrivers), target: self, x: 180, y: 145, in: drivers)
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
    }

    func apply(to result: inout VMSettings) throws {
        try VMDiskStore.validate(diskURL)
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
        result.diskPath = diskURL.path
        if usesEFI {
            result.installationMediaPath = restoreURL?.path
            result.bootFromInstaller = bootInstaller.state == .on
        } else {
            result.restoreImagePath = restoreURL?.path
        }
        result.driverMediaPath = driverURL?.path
        result.automaticWindowsDrivers = automaticDrivers.state == .on
        if protectsStartupDisk {
            result.diskPath = original.diskPath
            result.installationMediaPath = original.installationMediaPath
            result.bootFromInstaller = false
            result.driverMediaPath = original.driverMediaPath
            result.automaticWindowsDrivers = original.automaticWindowsDrivers
        }
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

    private func updateStorageLabels() {
        diskLabel.stringValue = diskURL.path
        let size = (try? diskURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        capacityLabel.stringValue = String(format: "%.1f GB capacity", Double(size) / 1_000_000_000)
        restoreLabel.stringValue =
            restoreURL?.path
            ?? (usesEFI && bundle?.distribution.hasAutomaticInstaller == false ? "Local ISO" : "Automatic")
    }

    @objc private func chooseDisk() {
        do {
            if let disk = try StartupDiskPicker.choose(usesEFI: usesEFI) {
                diskURL = disk
                updateStorageLabels()
            }
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func createDisk() {
        do {
            if let disk = try StartupDiskPicker.create(bundle: bundle) {
                diskURL = disk
                updateStorageLabels()
            }
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
}
