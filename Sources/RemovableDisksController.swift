import AppKit
import Virtualization

/// Runtime devices are separate from the startup disk and saved next-boot preferences.
@available(macOS 15.0, *)
@MainActor
final class RemovableDisksController: NSObject {
    private struct MountedDisk {
        let url: URL
        let device: VZUSBMassStorageDevice
        let readOnly: Bool
    }
    private let menu: NSMenu
    private weak var machine: VZVirtualMachine?
    private var bootDisk: URL?
    private var setupBusy = false
    private(set) var operationInProgress = false
    private var mounted: [String: MountedDisk] = [:]
    var stateDidChange: (() -> Void)?

    init(menu: NSMenu) {
        self.menu = menu
        super.init()
        menu.autoenablesItems = false
        rebuildMenu()
    }

    func update(machine: VZVirtualMachine?, bootDisk: URL?, busy: Bool) {
        if self.machine !== machine || machine?.state == .stopped || machine?.state == .error {
            mounted.removeAll()
        }
        self.machine = machine
        self.bootDisk = bootDisk
        setupBusy = busy
        rebuildMenu()
    }

    private var canChangeDevices: Bool {
        !setupBusy && !operationInProgress && machine?.state == .running
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let mount = menu.addItem(
            withTitle: "Mount Disk Image…", action: #selector(mountImage), keyEquivalent: "")
        mount.target = self
        mount.isEnabled = canChangeDevices
        menu.addItem(.separator())
        if mounted.isEmpty {
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
    }

    @objc private func mountImage() {
        guard canChangeDevices, let machine, let controller = machine.usbControllers.first else { return }
        let panel = NSOpenPanel()
        panel.title = "Mount Disk Image in VirtualMac"
        panel.message =
            "Choose a RAW disk image or ISO. Compressed DMG images must first be converted to RAW."
        panel.canChooseDirectories = false
        let readOnly = NSButton(checkboxWithTitle: "Read only", target: nil, action: nil)
        readOnly.state = .on
        readOnly.frame = NSRect(x: 0, y: 0, width: 220, height: 26)
        panel.accessoryView = readOnly
        guard panel.runModal() == .OK, let url = panel.url, canChangeDevices else { return }
        do {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard canonical != bootDisk?.standardizedFileURL.resolvingSymlinksInPath(),
                !mounted.values.contains(where: {
                    $0.url.standardizedFileURL.resolvingSymlinksInPath() == canonical
                })
            else {
                throw settingsError("This image is already connected or is the current startup disk.")
            }
            guard url.pathExtension.lowercased() != "dmg" else {
                throw settingsError(
                    "Convert this DMG to a RAW image before connecting it. Virtualization attaches disk sectors directly."
                )
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: url, readOnly: readOnly.state == .on)
            let device = VZUSBMassStorageDevice(
                configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
            operationInProgress = true
            rebuildMenu()
            Task {
                defer {
                    operationInProgress = false
                    rebuildMenu()
                    stateDidChange?()
                }
                do {
                    try await controller.attach(device: device)
                    mounted[UUID().uuidString] = MountedDisk(
                        url: url, device: device, readOnly: readOnly.state == .on)
                } catch { NSAlert(error: error).runModal() }
            }
        } catch { NSAlert(error: error).runModal() }
    }

    @objc private func unmountImage(_ sender: NSMenuItem) {
        guard canChangeDevices, let id = sender.representedObject as? String,
            let disk = mounted[id], let controller = disk.device.usbController
        else { return }
        let alert = NSAlert()
        alert.messageText = "Disconnect \(disk.url.lastPathComponent)?"
        alert.informativeText =
            "First eject its volumes in the guest’s Finder or Disk Utility so macOS finishes writing. Disconnecting removes the virtual USB drive; it does not delete the image."
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
