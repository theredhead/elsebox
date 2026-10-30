import AppKit
import Virtualization

struct VMRemovableMedium {
    let id: String
    let name: String
    let readOnly: Bool
    let isInstaller: Bool
    let canEject: Bool
}

/// Runtime devices are separate from the startup disk and saved next-boot preferences.
@available(macOS 15.0, *)
@MainActor
final class RemovableDisksController: NSObject, NSMenuDelegate {
    private struct MountedDisk {
        let url: URL
        let device: VZUSBMassStorageDevice
        let readOnly: Bool
    }

    private let menu: NSMenu
    private weak var machine: VZVirtualMachine?
    private var bootDisk: URL?
    private var installationMedia: URL?
    private var installationDevice: VZUSBMassStorageDevice?
    var guestToolsURL: URL?
    var installationMediaDidEject: (() throws -> Void)?

    var canMountImages: Bool { canChangeDevices }

    private var setupBusy = false
    private(set) var operationInProgress = false
    private var mounted: [String: MountedDisk] = [:]
    var stateDidChange: (() -> Void)?

    var connectedMedia: [VMRemovableMedium] {
        var result: [VMRemovableMedium] = []
        if installationDevice != nil, let installationMedia {
            result.append(
                VMRemovableMedium(
                    id: "installation", name: installationMedia.lastPathComponent,
                    readOnly: true, isInstaller: true, canEject: canChangeDevices))
        }
        result += mounted.sorted { $0.value.url.path < $1.value.url.path }.map { id, disk in
            VMRemovableMedium(
                id: id, name: disk.url.lastPathComponent, readOnly: disk.readOnly,
                isInstaller: false, canEject: canChangeDevices)
        }
        return result
    }

    func eject(id: String) {
        if id == "installation" {
            ejectInstallationMedia()
            return
        }

        let item = NSMenuItem()
        item.representedObject = id
        unmountImage(item)
    }

    init(menu: NSMenu) {
        self.menu = menu
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        rebuildMenu()
    }

    func update(machine: VZVirtualMachine?, bootDisk: URL?, installationMedia: URL?, busy: Bool) {
        if self.machine !== machine || machine?.state == .stopped || machine?.state == .error {
            mounted.removeAll()
            installationDevice = nil
        }
        self.machine = machine
        self.bootDisk = bootDisk
        setupBusy = busy
        self.installationMedia = installationMedia
        if installationMedia != nil, installationDevice == nil, machine?.state == .running {
            installationDevice = machine?.usbControllers.flatMap { $0.usbDevices }
                .compactMap { $0 as? VZUSBMassStorageDevice }
                .first { device in !mounted.values.contains(where: { $0.device === device }) }
        }
        rebuildMenu()
    }

    private var canChangeDevices: Bool {
        !setupBusy && !operationInProgress && machine?.state == .running
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        menu.removeAllItems()
        let mount = menu.addItem(
            withTitle: "Mount Disk Image…", action: #selector(mountImage), keyEquivalent: "")
        mount.target = self
        mount.isEnabled = canChangeDevices
        if let guestToolsURL {
            let tools = menu.addItem(
                withTitle: "Mount Windows Guest Tools", action: #selector(mountGuestTools), keyEquivalent: "")
            tools.target = self
            tools.isEnabled = canChangeDevices && !mounted.values.contains(where: { $0.url == guestToolsURL })
        }
        if installationDevice != nil {
            let eject = menu.addItem(
                withTitle: "Eject Installation Media", action: #selector(ejectInstallationMedia),
                keyEquivalent: "")
            eject.target = self
            eject.isEnabled = canChangeDevices
        }
        menu.addItem(.separator())
        if mounted.isEmpty && installationDevice == nil {
            let empty = menu.addItem(withTitle: "No disk images connected", action: nil, keyEquivalent: "")
            empty.isEnabled = false
        }
        for (id, disk) in mounted.sorted(by: { $0.value.url.path < $1.value.url.path }) {
            let item = menu.addItem(
                withTitle: "Unmount \(disk.url.lastPathComponent)\(disk.readOnly ? " (read only)" : "")…",
                action: #selector(unmountImage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.toolTip = disk.url.path
            item.isEnabled = canChangeDevices
        }

        let recent = RecentDiskImages.load()
        if !recent.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Recent"))
            for entry in recent {
                let item = menu.addItem(
                    withTitle: URL(fileURLWithPath: entry.path).lastPathComponent,
                    action: #selector(mountRecent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry
                item.toolTip = entry.path
                item.isEnabled =
                    canChangeDevices && entry.path != bootDisk?.path
                    && entry.path != installationMedia?.path
                    && !mounted.values.contains(where: { $0.url.path == entry.path })
            }
        }
    }

    @objc private func mountGuestTools() {
        if let guestToolsURL { mount([guestToolsURL], readOnly: true) }
    }

    @objc private func mountRecent(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? RecentDiskImage else { return }
        mount([URL(fileURLWithPath: entry.path)], readOnly: entry.readOnly)
    }

    @discardableResult
    func mountDroppedImages(_ urls: [URL]) -> Bool {
        guard canChangeDevices, !urls.isEmpty else { return false }
        mount(urls, readOnly: true)
        return true
    }

    @objc private func ejectInstallationMedia() {
        guard canChangeDevices, let device = installationDevice, let controller = device.usbController else {
            return
        }
        operationInProgress = true
        rebuildMenu()
        Task {
            defer {
                operationInProgress = false
                rebuildMenu()
                stateDidChange?()
            }
            do {
                try await controller.detach(device: device)
                installationDevice = nil
                installationMedia = nil
                try installationMediaDidEject?()
            } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func mountImage() {
        guard canChangeDevices else { return }

        let panel = NSOpenPanel()
        panel.title = "Mount Disk Image in ElseBox"
        panel.message =
            "Choose a RAW disk image or ISO. Compressed DMG images must first be converted to RAW."
        panel.canChooseDirectories = false
        let readOnly = NSButton(checkboxWithTitle: "Read only", target: nil, action: nil)
        readOnly.state = .on
        readOnly.frame = NSRect(x: 0, y: 0, width: 220, height: 26)
        panel.accessoryView = readOnly
        guard panel.runModal() == .OK, let url = panel.url, canChangeDevices else { return }
        mount([url], readOnly: readOnly.state == .on)
    }

    private func mount(_ urls: [URL], readOnly: Bool) {
        guard canChangeDevices, let machine, let controller = machine.usbControllers.first else { return }
        operationInProgress = true
        rebuildMenu()
        Task {
            defer {
                operationInProgress = false
                rebuildMenu()
                stateDidChange?()
            }
            do {
                for url in urls {
                    let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
                    guard canonical != bootDisk?.standardizedFileURL.resolvingSymlinksInPath(),
                        canonical != installationMedia?.standardizedFileURL.resolvingSymlinksInPath(),
                        !mounted.values.contains(where: {
                            $0.url.standardizedFileURL.resolvingSymlinksInPath() == canonical
                        })
                    else {
                        throw settingsError("This image is already connected or is the current startup disk.")
                    }
                    guard url.pathExtension.lowercased() != "dmg" else {
                        throw settingsError("Convert this DMG to a RAW image before connecting it.")
                    }

                    let attachment = try VZDiskImageStorageDeviceAttachment(
                        url: canonical, readOnly: readOnly)
                    let device = VZUSBMassStorageDevice(
                        configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
                    try await controller.attach(device: device)
                    mounted[UUID().uuidString] = MountedDisk(
                        url: canonical, device: device, readOnly: readOnly)
                    RecentDiskImages.remember(canonical, readOnly: readOnly)
                }
            } catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func unmountImage(_ sender: NSMenuItem) {
        guard canChangeDevices, let id = sender.representedObject as? String,
            let disk = mounted[id], let controller = disk.device.usbController
        else { return }

        let alert = NSAlert()
        alert.messageText = "Disconnect \(disk.url.lastPathComponent)?"
        alert.informativeText =
            "First eject its volumes inside the guest so it finishes writing. Disconnecting removes the virtual USB drive; it does not delete the image."
        alert.addButton(withTitle: "Disconnect")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, canChangeDevices else { return }
        operationInProgress = true
        rebuildMenu()
        Task {
            defer {
                operationInProgress = false
                rebuildMenu()
                stateDidChange?()
            }
            do {
                try await controller.detach(device: disk.device)
                mounted.removeValue(forKey: id)
            } catch { NSAlert(error: error).runModal() }
        }
    }
}
