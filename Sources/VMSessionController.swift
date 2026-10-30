import AppKit
import UniformTypeIdentifiers
import Virtualization

@MainActor
final class VMSessionController: NSObject, NSWindowDelegate, @preconcurrency VZVirtualMachineDelegate {
    private let identifier = "nl.theredhead.virtualmac"
    private var window: NSWindow!
    private let vmView = VMInputView()
    private let status = NSTextField(
        labelWithString: "Stopped")
    private let statusBar = NSView()
    private let activityView = VMActivityView()
    private var virtualMachine: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var busy = false
    private var configurationSaving = false
    var libraryPreparing = false { didSet { if libraryPreparing != oldValue { notifyStateChanged() } } }
    private var vmBottomWithStatus: NSLayoutConstraint!
    private var vmBottomWithoutStatus: NSLayoutConstraint!
    private var disksController: AnyObject?
    private var activeBootDisk: URL?
    private var activeDisplayResources: Resources?
    private var displayResizeTask: Task<Void, Never>?
    private var usesEntireDisplay = false
    private var enterEntireDisplayAfterNativeExit = false
    private var savedWindowFrame: NSRect?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []
    private let gib: UInt64 = 1024 * 1024 * 1024

    let bundle: VMBundle
    let disksMenu = NSMenu(title: "Disks")
    var stateDidChange: (() -> Void)?
    var didActivate: (() -> Void)?
    var willUseEntireDisplay: (() -> Void)?
    private var lease: VMLease?
    private var stoppedView: VMStoppedView!

    init(bundle: VMBundle) {
        self.bundle = bundle
        super.init()
        makeWindow()
    }

    private var directory: URL { bundle.url }
    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    var isActive: Bool {
        libraryPreparing || busy || configurationSaving || devicesBusy
            || (virtualMachine != nil && virtualMachine?.state != .stopped && virtualMachine?.state != .error)
    }
    var stateLabel: String {
        if busy { return "Preparing…" }
        if configurationSaving { return "Saving settings…" }
        switch virtualMachine?.state {
        case .running: return "Running"
        case .paused: return "Paused"
        case .error: return "Stopped after error"
        default: return "Stopped"
        }
    }
    var statusBarVisible: Bool { !statusBar.isHidden }
    var entireDisplay: Bool { usesEntireDisplay }
    var nativeFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    func showWindow() { window.makeKeyAndOrderFront(nil) }
    func closeWindow() { window.close() }
    var canConfigure: Bool { !libraryPreparing && !configurationSaving && !busy }
    func exitEntireDisplayIfNeeded() { if usesEntireDisplay { leaveEntireDisplay() } }
    func windowDidBecomeKey(_ notification: Notification) { didActivate?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isActive else {
            NSAlert(
                error: failure(
                    "Shut down this guest before closing its window. You can switch to the VM Library to use another VM."
                )
            ).runModal()
            return false
        }
        exitEntireDisplayIfNeeded()
        return true
    }

    var canStart: Bool {
        !libraryPreparing && !busy && !configurationSaving && !devicesBusy
            && (virtualMachine == nil || virtualMachine?.state == .stopped || virtualMachine?.state == .error)
    }

    func startVirtualMachine(_ sender: Any? = nil) {
        guard canStart else { return }
        busy = true
        notifyStateChanged()
        updateDeviceMenu()
        window.makeKeyAndOrderFront(nil)
        Task {
            defer {
                busy = false
                if canStart {
                    vmView.virtualMachine = nil
                    virtualMachine = nil
                    lease = nil
                }
                notifyStateChanged()
                updateDeviceMenu()
            }
            do {
                // Snapshot preferences before downloading or installing; later edits apply next boot.
                lease = try VMLease(directory: bundle.url)
                let resources = try bootResources()
                vmView.virtualMachine = nil
                virtualMachine = nil
                try await prepareAndRun(resources: resources)
            } catch is CancellationError {
                activityView.stop()
                status.stringValue = "Stopped"
            } catch {
                activityView.stop()
                installer = nil
                status.stringValue = "Startup failed: \(error.localizedDescription)"
                NSAlert(error: error).runModal()
            }
        }
    }

    func showPreferences(_ sender: Any? = nil) {
        guard canConfigure else { return }
        do {
            let resources = try preferredResources()
            let limits = try resourceLimits(
                metadata: VMDiskStore.metadata(for: VMDiskStore.disk(for: resources)))
            let editor = PreferencesEditor(
                settings: resources, cpuLimits: limits.cpu,
                memoryLimits: limits.memoryGiB, hostAspectRatio: hostAspectRatio, bundle: bundle)
            let alert = NSAlert()
            alert.messageText = "\(bundle.name) — Configuration"
            alert.informativeText = "Changes apply on the next start."
            alert.accessoryView = editor
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            // Leave all controls intact when validation fails.
            while alert.runModal() == .alertFirstButtonReturn {
                do {
                    let updated = try editor.settings()
                    configurationSaving = true
                    notifyStateChanged()
                    let bundle = self.bundle
                    Task {
                        defer {
                            configurationSaving = false
                            notifyStateChanged()
                            updateDeviceMenu()
                        }
                        do {
                            try await InstallerPreparation.save(bundle: bundle, settings: updated)
                        } catch is CancellationError {
                            // Keep the previous saved configuration when preparation is cancelled.
                        } catch { NSAlert(error: error).runModal() }
                    }
                    break
                } catch { NSAlert(error: error).runModal() }
            }
        } catch { NSAlert(error: error).runModal() }
    }

    private var hostAspectRatio: Double {
        if usesEntireDisplay || window.styleMask.contains(.fullScreen), vmView.bounds.width > 0,
            vmView.bounds.height > 0
        {
            return vmView.bounds.width / vmView.bounds.height
        }
        let size = (window.screen ?? NSScreen.main)?.frame.size ?? NSSize(width: 1920, height: 1080)
        return size.width / size.height
    }

    private func bootResources() throws -> Resources {
        let preferences = try preferredResources()
        if bundle.distribution == .windows {
            var snapshot = preferences
            snapshot.displayWidth = 1024
            snapshot.displayHeight = 768
            snapshot.keepHostAspectRatio = false
            return snapshot
        }
        guard preferences.keepHostAspectRatio == true else { return preferences }
        let options = ResolutionPicker.resolutions(hostAspectRatio: hostAspectRatio)
        guard
            let selected = options.min(by: {
                abs($0.width - (preferences.displayWidth ?? 1920))
                    < abs($1.width - (preferences.displayWidth ?? 1920))
            })
        else {
            throw failure(
                "This host display’s aspect ratio has no supported resolution. Disable aspect ratio matching in Preferences."
            )
        }
        var snapshot = preferences
        snapshot.displayWidth = selected.width
        snapshot.displayHeight = selected.height
        return snapshot
    }

    private func preferredResources() throws -> Resources { try bundle.resolvedSettings() }

    private func resourceLimits(metadata: URL) throws -> (cpu: ClosedRange<Int>, memoryGiB: ClosedRange<Int>)
    {
        var minimum = Resources(
            cpu: bundle.distribution.isLinux ? 1 : 2, memory: bundle.distribution.isLinux ? gib : 4 * gib)
        if FileManager.default.fileExists(
            atPath: metadata.appendingPathComponent("MinimumResources.json").path)
        {
            minimum = try JSONDecoder().decode(
                Resources.self,
                from: Data(contentsOf: metadata.appendingPathComponent("MinimumResources.json")))
        }
        let minCPU = max(minimum.cpu, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let maxCPU = min(
            ProcessInfo.processInfo.processorCount,
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let minMemory = Int(
            (max(minimum.memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize) + gib - 1) / gib)
        let maxMemory = Int(
            min(
                ProcessInfo.processInfo.physicalMemory, VZVirtualMachineConfiguration.maximumAllowedMemorySize
            ) / gib)
        guard minCPU <= maxCPU, minMemory <= maxMemory else {
            throw failure("This Mac cannot provide the virtual machine’s minimum CPU or memory requirements.")
        }
        return (minCPU...maxCPU, minMemory...maxMemory)
    }

    private func makeWindow() {
        if #available(macOS 15.0, *) {
            let controller = RemovableDisksController(menu: disksMenu)
            controller.stateDidChange = { [weak self] in
                self?.notifyStateChanged()
                self?.updateDeviceMenu()
            }
            disksController = controller
        } else {
            let item = disksMenu.addItem(
                withTitle: "Live disks require macOS Sequoia 15 or later", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        window = VMWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = bundle.name
        window.isReleasedWhenClosed = false
        window.delegate = self
        vmView.viewportDidChange = { [weak self] in self?.scheduleDisplayFit() }
        let content = window.contentView!
        vmView.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(vmView)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        activityView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusBar)
        statusBar.addSubview(status)
        statusBar.addSubview(activityView)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        vmBottomWithStatus = vmView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4)
        vmBottomWithoutStatus = vmView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
            status.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            activityView.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 12),
            activityView.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            activityView.topAnchor.constraint(equalTo: statusBar.topAnchor),
            activityView.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor),
            vmView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            vmView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            vmView.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        setStatusBarVisible((try? preferredResources().showsStatusBar) ?? true)
        stoppedView = VMStoppedView(bundle: bundle)
        stoppedView.onStart = { [weak self] in self?.startVirtualMachine() }
        stoppedView.onConfigure = { [weak self] in self?.showPreferences() }
        stoppedView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stoppedView)
        NSLayoutConstraint.activate([
            stoppedView.leadingAnchor.constraint(equalTo: vmView.leadingAnchor),
            stoppedView.trailingAnchor.constraint(equalTo: vmView.trailingAnchor),
            stoppedView.topAnchor.constraint(equalTo: vmView.topAnchor),
            stoppedView.bottomAnchor.constraint(equalTo: vmView.bottomAnchor),
        ])
        vmView.capturesSystemKeys = true
        window.center()
    }

    func toggleStatusBar(_ sender: Any? = nil) {
        guard !configurationSaving else { return }
        let visible = statusBar.isHidden
        do {
            var settings = try preferredResources()
            settings.showsStatusBar = visible
            try bundle.save(settings)
            setStatusBarVisible(visible)
        } catch { NSAlert(error: error).runModal() }
    }

    private func setStatusBarVisible(_ visible: Bool) {
        statusBar.isHidden = !visible
        NSLayoutConstraint.deactivate([vmBottomWithStatus, vmBottomWithoutStatus])
        (visible ? vmBottomWithStatus : vmBottomWithoutStatus).isActive = true
        notifyStateChanged()
        window.contentView?.layoutSubtreeIfNeeded()
        scheduleDisplayFit()
    }

    func toggleEntireDisplay(_ sender: Any? = nil) {
        if usesEntireDisplay {
            leaveEntireDisplay()
        } else if window.styleMask.contains(.fullScreen) {
            enterEntireDisplayAfterNativeExit = true
            window.toggleFullScreen(nil)
        } else {
            enterEntireDisplay()
        }
    }

    func toggleNativeFullScreen(_ sender: Any? = nil) {
        if usesEntireDisplay {
            leaveEntireDisplay()
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.window.toggleFullScreen(nil)
            }
        } else {
            window.toggleFullScreen(nil)
        }
    }

    private func enterEntireDisplay() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        willUseEntireDisplay?()
        savedWindowFrame = window.frame
        savedPresentationOptions = NSApp.presentationOptions
        usesEntireDisplay = true
        notifyStateChanged()
        NSApp.presentationOptions =
            savedPresentationOptions
            .subtracting([.hideDock, .hideMenuBar])
            .union([.autoHideDock, .autoHideMenuBar])
        window.styleMask = [.borderless]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(vmView)
        scheduleDisplayFit()
    }

    private func leaveEntireDisplay() {
        usesEntireDisplay = false
        notifyStateChanged()
        NSApp.presentationOptions = savedPresentationOptions
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        if let frame = savedWindowFrame { window.setFrame(frame, display: true) }
        window.makeKeyAndOrderFront(nil)
        scheduleDisplayFit()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        notifyStateChanged()
        scheduleDisplayFit()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        notifyStateChanged()
        if enterEntireDisplayAfterNativeExit {
            enterEntireDisplayAfterNativeExit = false
            // Let AppKit finish restoring normal presentation before entering borderless mode.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.enterEntireDisplay()
            }
        } else {
            scheduleDisplayFit()
        }
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        enterEntireDisplayAfterNativeExit = false
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if usesEntireDisplay, let screen = window.screen { window.setFrame(screen.frame, display: true) }
        scheduleDisplayFit()
    }

    func windowDidResize(_ notification: Notification) { scheduleDisplayFit() }

    private func scheduleDisplayFit() {
        displayResizeTask?.cancel()
        guard let resources = activeDisplayResources, resources.keepHostAspectRatio == true,
            virtualMachine?.state == .running
        else { return }
        displayResizeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let self, let machine = self.virtualMachine, machine.state == .running,
                let display = machine.graphicsDevices.first?.displays.first
            else { return }
            let size: CGSize
            if self.usesEntireDisplay || self.window.styleMask.contains(.fullScreen) {
                guard
                    let fitted = DisplayLayout.fittedSize(
                        viewport: self.vmView.bounds.size,
                        preferredWidth: resources.displayWidth ?? 1920)
                else { return }
                size = fitted
            } else {
                size = CGSize(width: resources.displayWidth ?? 1920, height: resources.displayHeight ?? 1080)
            }
            guard display.sizeInPixels != size else { return }
            do { try display.reconfigure(sizeInPixels: size) } catch {
                self.status.stringValue = "Could not fit guest display: \(error.localizedDescription)"
            }
        }
    }

    private func prepareAndRun(resources initialResources: Resources) async throws {
        var resources = initialResources
        guard VZVirtualMachine.isSupported else {
            throw failure("Virtualization is unavailable on this host.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disk = VMDiskStore.disk(for: resources)
        try VMDiskStore.validate(disk)
        let metadata = VMDiskStore.metadata(for: disk)
        if resources.sharedFolders == nil {
            try FileManager.default.createDirectory(at: file("Shared"), withIntermediateDirectories: true)
        }

        if bundle.distribution.hasAutomaticInstaller
            && InstallerMediaService.needsDownload(bundle: bundle, settings: resources)
        {
            resources = try await InstallerPreparation.save(bundle: bundle, settings: resources)
        }
        let installed = FileManager.default.fileExists(
            atPath: metadata.appendingPathComponent("Installed").path)
        var restoreURL: URL?
        if bundle.distribution.usesEFI {
            if resources.bootFromInstaller != false && resources.installationMediaPath == nil {
                let panel = NSOpenPanel()
                panel.title = bundle.distribution.installerSelectionTitle
                panel.message = bundle.distribution.installerSelectionMessage
                panel.prompt = "Choose Installer"
                panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
                guard panel.runModal() == .OK, let source = panel.url else { throw CancellationError() }
                resources.installationMediaPath = source.path
                resources.bootFromInstaller = true
                resources = try await InstallerPreparation.save(bundle: bundle, settings: resources)
            }
        } else if !installed {
            restoreURL = try restoreImageURL(resources: resources)
            try await preparePlatform(using: restoreURL!, metadata: metadata)
        }
        if bundle.distribution == .windows, resources.bootFromInstaller != false {
            status.stringValue = "Preparing Windows bootstrap media…"
            resources.installationMediaPath = try await WindowsBootMedia.prepare(
                bundle: bundle, resources: resources
            ).path
        }
        let configuration =
            try bundle.distribution.usesEFI
            ? EFIVMConfiguration.make(bundle: bundle, resources: resources)
            : makeConfiguration(resources: resources)
        try configuration.validate()
        let machine = VZVirtualMachine(configuration: configuration)
        machine.delegate = self
        virtualMachine = machine
        activityView.start(allocatedMemory: configuration.memorySize) { [weak machine] in
            guard let machine, machine.state == .running || machine.state == .starting else { return nil }
            return VMHostMetricsSource.read(machine)
        }
        activeBootDisk = disk
        activeDisplayResources = resources
        updateDeviceMenu()
        vmView.usesUSBMouse = bundle.distribution.usesEFI || resources.useMacTrackpad != true
        vmView.virtualMachine = machine
        if let restoreURL {
            status.stringValue = "Installing macOS… This may take a while."
            let installation = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restoreURL)
            installer = installation
            try await installation.install()
            installer = nil
            try Data().write(to: metadata.appendingPathComponent("Installed"), options: .atomic)
        }
        status.stringValue = "Starting \(bundle.distribution.title)…"
        if machine.state == .stopped { try await machine.start() }
        status.stringValue = "\(bundle.distribution.title) — Running"
        scheduleDisplayFit()
    }

    private func restoreImageURL(resources: Resources) throws -> URL {
        guard let path = resources.restoreImagePath, FileManager.default.isReadableFile(atPath: path) else {
            throw failure(
                "The macOS restore image is unavailable. Save this VM’s configuration to prepare it again.")
        }
        return URL(fileURLWithPath: path)
    }

    private func preparePlatform(using restoreURL: URL, metadata: URL) async throws {
        let restore = try await VZMacOSRestoreImage.image(from: restoreURL)
        guard let requirements = restore.mostFeaturefulSupportedConfiguration else {
            throw failure("This restore image is incompatible with this Mac.")
        }
        if FileManager.default.fileExists(atPath: metadata.appendingPathComponent("HardwareModel").path) {
            let savedModel = try Data(contentsOf: metadata.appendingPathComponent("HardwareModel"))
            guard savedModel == requirements.hardwareModel.dataRepresentation else {
                throw failure(
                    "This restore image requires a different hardware model. Use the original restore image for this disk, or create a new disk for this installation."
                )
            }
        }
        // Persist before installation, so an interrupted installation can be retried.
        if !FileManager.default.fileExists(atPath: metadata.appendingPathComponent("HardwareModel").path) {
            try requirements.hardwareModel.dataRepresentation.write(
                to: metadata.appendingPathComponent("HardwareModel"), options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: metadata.appendingPathComponent("MachineIdentifier").path)
        {
            try VZMacMachineIdentifier().dataRepresentation.write(
                to: metadata.appendingPathComponent("MachineIdentifier"), options: .atomic)
        }
        let minimum = Resources(
            cpu: requirements.minimumSupportedCPUCount, memory: requirements.minimumSupportedMemorySize)
        try JSONEncoder().encode(minimum).write(
            to: metadata.appendingPathComponent("MinimumResources.json"), options: .atomic)
        if !FileManager.default.fileExists(atPath: metadata.appendingPathComponent("AuxiliaryStorage").path) {
            guard
                let model = VZMacHardwareModel(
                    dataRepresentation: try Data(contentsOf: metadata.appendingPathComponent("HardwareModel"))
                )
            else {
                throw failure("Invalid saved hardware model.")
            }
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: metadata.appendingPathComponent("AuxiliaryStorage"), hardwareModel: model,
                options: [])
        }
    }

    private func makeConfiguration(resources: Resources) throws -> VZVirtualMachineConfiguration {
        let disk = VMDiskStore.disk(for: resources)
        let metadata = VMDiskStore.metadata(for: disk)
        guard
            let model = VZMacHardwareModel(
                dataRepresentation: try Data(contentsOf: metadata.appendingPathComponent("HardwareModel"))),
            model.isSupported,
            let machineID = VZMacMachineIdentifier(
                dataRepresentation: try Data(contentsOf: metadata.appendingPathComponent("MachineIdentifier"))
            )
        else {
            throw failure("The saved VM identity is invalid or unsupported on this Mac.")
        }
        let limits = try resourceLimits(metadata: metadata)
        // Raise preferences to guest minimums and constrain them to this host.
        let cpuCount = min(max(resources.cpu, limits.cpu.lowerBound), limits.cpu.upperBound)
        let memorySize = min(
            max(resources.memory, UInt64(limits.memoryGiB.lowerBound) * gib),
            UInt64(limits.memoryGiB.upperBound) * gib)
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = cpuCount
        configuration.memorySize = memorySize
        configuration.audioDevices = VMAudioConfiguration.devices(resources: resources)
        configuration.bootLoader = VZMacOSBootLoader()
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = machineID
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(
            contentsOf: metadata.appendingPathComponent("AuxiliaryStorage"))
        configuration.platform = platform
        let attachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        if #available(macOS 15.0, *) {
            configuration.usbControllers = [VZXHCIControllerConfiguration()]
        }
        let graphics = VZMacGraphicsDeviceConfiguration()
        let displayWidth = resources.displayWidth ?? 1920
        let displayHeight = resources.displayHeight ?? 1080
        try validateDisplay(width: displayWidth, height: displayHeight)
        guard (36...300).contains(resources.pixelsPerInch ?? 72) else {
            throw failure("Display density must be between 36 and 300 PPI.")
        }
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: displayWidth,
                heightInPixels: displayHeight,
                pixelsPerInch: resources.pixelsPerInch ?? 72)
        ]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        if resources.useMacTrackpad == true {
            configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        } else {
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
        let shares =
            resources.sharedFolders ?? [
                SharedFolder(name: "Shared", path: file("Shared").path, readOnly: false)
            ]
        try VMDiskStore.validateShares(shares)
        if !shares.isEmpty {
            let sharing = VZVirtioFileSystemDeviceConfiguration(
                tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            let directories = Dictionary(
                uniqueKeysWithValues: shares.map {
                    ($0.name, VZSharedDirectory(url: URL(fileURLWithPath: $0.path), readOnly: $0.readOnly))
                })
            sharing.share = VZMultipleDirectoryShare(directories: directories)
            configuration.directorySharingDevices = [sharing]
        }
        return configuration
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        displayResizeTask?.cancel()
        activityView.stop()
        status.stringValue = "Stopped"
        if !busy {
            vmView.virtualMachine = nil
            self.virtualMachine = nil
            lease = nil
        }
        if bundle.distribution == .windows,
            (try? preferredResources().bootFromInstaller) != false
        {
            configurationSaving = true
            Task {
                var installed = false
                defer {
                    configurationSaving = false
                    notifyStateChanged()
                    if installed { startVirtualMachine() }
                }
                do {
                    if try await WindowsBootMedia.installationSucceeded(bundle: bundle) {
                        var settings = try preferredResources()
                        settings.bootFromInstaller = false
                        if settings.windowsUnattended == true {
                            settings.audioOutputEnabled = settings.experimentalWindowsAudio == true
                        }
                        try WindowsBootMedia.rememberDrivers(bundle: bundle, resources: settings)
                        try bundle.save(settings)
                        if settings.windowsUnattended == true {
                            try WindowsSetupSecret.remove(for: bundle.id)
                        }
                        installed = true
                    }
                } catch {
                    status.stringValue = "Windows deployment failed"
                    NSAlert(error: error).runModal()
                }
            }
        }
        notifyStateChanged()
        updateDeviceMenu()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        displayResizeTask?.cancel()
        activityView.stop()
        status.stringValue = "Virtual machine stopped: \(error.localizedDescription)"
        if !busy {
            vmView.virtualMachine = nil
            self.virtualMachine = nil
            lease = nil
        }
        notifyStateChanged()
        updateDeviceMenu()
    }

    private var devicesBusy: Bool {
        if #available(macOS 15.0, *), let devices = disksController as? RemovableDisksController {
            return devices.operationInProgress
        }
        return false
    }

    private func updateDeviceMenu() {
        if #available(macOS 15.0, *), let devices = disksController as? RemovableDisksController {
            devices.update(
                machine: virtualMachine, bootDisk: activeBootDisk, busy: busy || configurationSaving)
        }
    }

    private func validateDisplay(width: Int, height: Int) throws {
        guard (640...7680).contains(width), (480...4320).contains(height) else {
            throw failure("Display width must be 640–7680 pixels and height must be 480–4320 pixels.")
        }
    }

    func bootFromStartupDisk() {
        guard canStart, bundle.distribution.usesEFI else { return }
        do {
            var settings = try preferredResources()
            settings.bootFromInstaller = false
            try bundle.save(settings)
            notifyStateChanged()
        } catch { NSAlert(error: error).runModal() }
    }

    private func notifyStateChanged() {
        if let stoppedView {
            stoppedView.isHidden =
                busy
                || (virtualMachine != nil && virtualMachine?.state != .stopped
                    && virtualMachine?.state != .error)
            stoppedView.refresh(canStart: canStart, canConfigure: canConfigure)
        }
        stateDidChange?()
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: identifier, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
