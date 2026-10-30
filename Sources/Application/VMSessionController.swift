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
    private lazy var networkMonitor = VMNetworkMonitor(bundleURL: bundle.url)
    var networkDidChange: (() -> Void)?
    var networkSnapshot: VMNetworkSnapshot? { networkMonitor.snapshot }
    var networkIsLive: Bool { networkMonitor.isLive }
    private lazy var thumbnails = VMThumbnailController(bundle: bundle)
    private var virtualMachine: VZVirtualMachine?
    private var installer: VZMacOSInstaller?
    private var busy = false
    private var configurationSaving = false
    private var forceStopping = false
    private var stopWasRequested = false
    private var closeWhenStopped = false
    private var libraryPreparing: Bool { InstallerPreparation.isPreparing(bundle.id) }
    private var vmBottomWithStatus: NSLayoutConstraint!
    private var vmBottomWithoutStatus: NSLayoutConstraint!
    private var disksController: AnyObject?
    private var activeBootDisk: URL?
    private var activeInstallationMedia: URL?
    private var activeDisplayResources: VMSettings?
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
        networkMonitor.didChange = { [weak self] in self?.networkDidChange?() }
    }

    private var directory: URL { bundle.url }
    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }
    var isActive: Bool {
        forceStopping || libraryPreparing || busy || configurationSaving || devicesBusy
            || (virtualMachine != nil && virtualMachine?.state != .stopped && virtualMachine?.state != .error)
    }
    var stateLabel: String {
        if forceStopping { return "Stopping…" }
        if busy { return installer != nil ? "Installing macOS…" : "Preparing…" }
        if configurationSaving { return "Saving settings…" }
        switch virtualMachine?.state {
        case .running: return "Running"
        case .paused: return "Paused"
        case .error: return "Stopped after error"
        default: return "Stopped"
        }
    }
    var removableMedia: [VMRemovableMedium] {
        if hasRunningGuest, #available(macOS 15.0, *),
            let devices = disksController as? RemovableDisksController
        {
            return devices.connectedMedia
        }
        return Self.configuredInstallationMedia(bundle: bundle, canEject: canStart)
    }

    static func configuredInstallationMedia(bundle: VMBundle, canEject: Bool) -> [VMRemovableMedium] {
        guard bundle.distribution.usesEFI, let settings = try? bundle.resolvedSettings(),
            settings.bootFromInstaller != false, let path = settings.installationMediaPath
        else { return [] }
        return [
            VMRemovableMedium(
                id: "installation", name: URL(fileURLWithPath: path).lastPathComponent,
                readOnly: true, isInstaller: true, canEject: canEject)
        ]
    }

    func ejectRemovableMedia(id: String) {
        if hasRunningGuest, #available(macOS 15.0, *),
            let devices = disksController as? RemovableDisksController
        {
            devices.eject(id: id)
        } else if canStart, id == "installation" {
            do {
                try releaseInstallationMedia()
                notifyStateChanged()
            } catch { NSAlert(error: error).runModal() }
        }
    }

    var activityCounters: VMActivityCounters? {
        guard let virtualMachine, virtualMachine.state == .running else { return nil }
        return VMHostMetricsSource.read(virtualMachine)
    }
    var isPreparingMedia: Bool { busy || configurationSaving || libraryPreparing }
    var hasRunningGuest: Bool { virtualMachine?.state == .running }
    var previewMachine: VZVirtualMachine? {
        guard let virtualMachine, virtualMachine.state == .running || virtualMachine.state == .paused else {
            return nil
        }
        return virtualMachine
    }
    var statusBarVisible: Bool { !statusBar.isHidden }
    var entireDisplay: Bool { usesEntireDisplay }
    var nativeFullScreen: Bool { window.styleMask.contains(.fullScreen) }

    private var opensVMWindowOnStart = true

    func showWindow() {
        opensVMWindowOnStart = true
        window.makeKeyAndOrderFront(nil)
    }
    func closeWindow() { window.close() }
    var canConfigure: Bool { !configurationSaving && !busy && !forceStopping }
    var canShutDown: Bool { virtualMachine?.canRequestStop == true && !forceStopping }
    var canForceStop: Bool { virtualMachine?.canStop == true && !forceStopping }
    func exitEntireDisplayIfNeeded() { if usesEntireDisplay { leaveEntireDisplay() } }
    func windowDidBecomeKey(_ notification: Notification) { didActivate?() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard isActive else {
            exitEntireDisplayIfNeeded()
            return true
        }
        let alert = NSAlert()
        alert.messageText = "Close \(bundle.name)?"
        alert.informativeText = "Go headless to keep the VM running without its console window."
        alert.addButton(withTitle: "Go Headless")
        let shutdown = canShutDown ? alert.addButton(withTitle: "Shut Down") : nil
        let force = canForceStop ? alert.addButton(withTitle: "Force Stop…") : nil
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            opensVMWindowOnStart = false
            exitEntireDisplayIfNeeded()
            return true
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard alert.buttons.indices.contains(index) else { return false }
        let selected = alert.buttons[index]
        if selected === shutdown {
            closeWhenStopped = true
            shutDown()
        } else if selected === force {
            forceStop(closeAfterStopping: true)
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        opensVMWindowOnStart = false
    }

    func shutDown() {
        guard canShutDown, let virtualMachine else { return }
        do {
            try virtualMachine.requestStop()
            stopWasRequested = true
            status.stringValue = "Shutting down…"
        } catch {
            closeWhenStopped = false
            NSAlert(error: error).runModal()
        }
    }

    func forceStop(closeAfterStopping: Bool = false) {
        guard canForceStop, let machine = virtualMachine else { return }
        let alert = NSAlert()
        alert.messageText = "Force stop \(bundle.name)?"
        alert.informativeText =
            "This turns off the virtual machine immediately. Unsaved guest changes may be lost."
        alert.addButton(withTitle: "Force Stop")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        closeWhenStopped = closeAfterStopping
        stopWasRequested = true
        forceStopping = true
        status.stringValue = "Stopping…"
        notifyStateChanged()
        updateDeviceMenu()
        Task {
            defer {
                forceStopping = false
                notifyStateChanged()
                updateDeviceMenu()
            }
            do {
                try await machine.stop()
                networkMonitor.stop()
                activityView.stop()
                displayResizeTask?.cancel()
                vmView.virtualMachine = nil
                virtualMachine = nil
                installer = nil
                if !busy { lease = nil }
                status.stringValue = "Stopped"
            } catch {
                closeWhenStopped = false
                NSAlert(error: error).runModal()
            }
        }
    }

    var canStart: Bool {
        InstallerPreparation.canStart(bundle: bundle)
            && !forceStopping && !libraryPreparing && !busy && !configurationSaving && !devicesBusy
            && (virtualMachine == nil || virtualMachine?.state == .stopped || virtualMachine?.state == .error)
    }

    func startVirtualMachine(_ sender: Any? = nil, headless: Bool? = nil) {
        guard canStart else { return }
        stopWasRequested = false
        closeWhenStopped = false
        busy = true
        notifyStateChanged()
        updateDeviceMenu()
        let startsHeadless = headless ?? ((try? preferredResources())?.startHeadless ?? false)
        opensVMWindowOnStart = !startsHeadless
        if startsHeadless {
            window.orderOut(nil)
        } else {
            showWindow()
        }
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
                if stopWasRequested {
                    status.stringValue = "Stopped"
                } else {
                    status.stringValue = "Startup failed: \(error.localizedDescription)"
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    func showPreferences(_ sender: Any? = nil) {
        guard canConfigure else { return }
        do {
            let resources = try preferredResources()
            let limits = try VMResourceLimits.load(
                metadata: VMDiskStore.metadata(for: VMDiskStore.disk(for: resources)),
                distribution: bundle.distribution)
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
                    try InstallerPreparation.begin(bundle: bundle, settings: updated)
                    notifyStateChanged()
                    updateDeviceMenu()
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

    private func bootResources() throws -> VMSettings {
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

    private func preferredResources() throws -> VMSettings { try bundle.resolvedSettings() }

    private func makeWindow() {
        if #available(macOS 15.0, *) {
            let controller = RemovableDisksController(menu: disksMenu)
            controller.stateDidChange = { [weak self] in
                self?.notifyStateChanged()
                self?.updateDeviceMenu()
            }
            controller.guestToolsURL = bundle.distribution == .windows ? BundledGuestTools.imageURL : nil
            controller.installationMediaDidEject = { [weak self] in try self?.releaseInstallationMedia() }
            disksController = controller
            vmView.canMountImages = { [weak controller] in controller?.canMountImages == true }
            vmView.mountImages = { [weak controller] in controller?.mountDroppedImages($0) ?? false }
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
            activityView.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 12),
            activityView.widthAnchor.constraint(equalToConstant: 234),
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

    private func prepareAndRun(resources initialResources: VMSettings) async throws {
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
            try await MacVMConfiguration.preparePlatform(using: restoreURL!, metadata: metadata)
        }
        if bundle.distribution == .windows, resources.bootFromInstaller != false {
            status.stringValue = "Preparing Windows bootstrap media…"
            resources.installationMediaPath = try await WindowsBootMedia.prepare(
                bundle: bundle, resources: resources
            ).path
        }
        activeInstallationMedia =
            bundle.distribution.usesEFI && resources.bootFromInstaller != false
            ? resources.installationMediaPath.map { URL(fileURLWithPath: $0) } : nil
        let configuration =
            try bundle.distribution.usesEFI
            ? EFIVMConfiguration.make(bundle: bundle, resources: resources)
            : MacVMConfiguration.make(bundle: bundle, resources: resources)
        try configuration.validate()
        var machine = VZVirtualMachine(configuration: configuration)
        attachRuntime(machine, memorySize: configuration.memorySize)
        activeBootDisk = disk
        activeDisplayResources = resources
        updateDeviceMenu()
        vmView.usesUSBMouse = bundle.distribution.usesEFI || resources.useMacTrackpad != true
        vmView.virtualMachine = machine
        if let restoreURL {
            status.stringValue = "Installing macOS… This may take a while."
            let installation = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: restoreURL)
            installer = installation
            notifyStateChanged()
            try await installation.install()
            installer = nil
            try Data().write(to: metadata.appendingPathComponent("Installed"), options: .atomic)
            try releaseInstallationMedia()
            // The restore VM has its own shutdown lifecycle. Never reuse it for the first normal boot.
            machine.delegate = nil
            if machine.canStop { try await machine.stop() }
            let deadline = Date().addingTimeInterval(30)
            while machine.state == .stopping, Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard machine.state == .stopped else {
                throw failure(
                    "macOS installation completed, but the installer VM has not stopped. Start this VM again to boot the installed system."
                )
            }
            machine = VZVirtualMachine(configuration: configuration)
            attachRuntime(machine, memorySize: configuration.memorySize)
            notifyStateChanged()
        }
        status.stringValue = "Starting \(bundle.distribution.title)…"
        if machine.state == .stopped { try await machine.start() }
        networkMonitor.start(macAddresses: configuration.networkDevices.map { $0.macAddress.string })
        status.stringValue = "\(bundle.distribution.title) — Running"
        if !bundle.distribution.usesEFI || resources.bootFromInstaller == false {
            try releaseInstallationMedia()
        }
        scheduleDisplayFit()
    }

    private func attachRuntime(_ machine: VZVirtualMachine, memorySize: UInt64) {
        machine.delegate = self
        virtualMachine = machine
        vmView.virtualMachine = machine
        activityView.start(allocatedMemory: memorySize) { [weak machine] in
            guard let machine, machine.state == .running || machine.state == .starting else { return nil }
            return VMHostMetricsSource.read(machine)
        }
    }

    private func restoreImageURL(resources: VMSettings) throws -> URL {
        guard let path = resources.restoreImagePath, FileManager.default.isReadableFile(atPath: path) else {
            throw failure(
                "The macOS restore image is unavailable. Save this VM’s configuration to prepare it again.")
        }
        return URL(fileURLWithPath: path)
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard virtualMachine === self.virtualMachine else { return }
        displayResizeTask?.cancel()
        networkMonitor.stop()
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
                    if installed && !stopWasRequested {
                        startVirtualMachine(headless: !opensVMWindowOnStart)
                    }
                }
                do {
                    if try await WindowsBootMedia.installationSucceeded(bundle: bundle) {
                        var settings = try preferredResources()
                        settings.bootFromInstaller = false
                        if settings.windowsUnattended == true {
                            settings.audioOutputEnabled = settings.experimentalWindowsAudio == true
                        }
                        try WindowsBootMedia.rememberDrivers(bundle: bundle, resources: settings)
                        settings.installationMediaPath = nil
                        settings.driverMediaPath = nil
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
        guard virtualMachine === self.virtualMachine else { return }
        displayResizeTask?.cancel()
        networkMonitor.stop()
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
                machine: virtualMachine, bootDisk: activeBootDisk, installationMedia: activeInstallationMedia,
                busy: busy || configurationSaving)
        }
    }

    func bootFromStartupDisk() {
        guard canStart, bundle.distribution.usesEFI else { return }
        do {
            try releaseInstallationMedia()
            notifyStateChanged()
        } catch { NSAlert(error: error).runModal() }
    }

    private func releaseInstallationMedia() throws {
        var settings = try preferredResources()
        if bundle.distribution == .windows {
            try WindowsBootMedia.rememberDrivers(bundle: bundle, resources: settings)
        }
        settings.bootFromInstaller = false
        settings.restoreImagePath = nil
        settings.installationMediaPath = nil
        settings.driverMediaPath = nil
        try bundle.save(settings)
        activeInstallationMedia = nil
    }

    private func notifyStateChanged() {
        thumbnails.update(view: vmView, running: virtualMachine?.state == .running)
        if let stoppedView {
            stoppedView.isHidden =
                busy
                || (virtualMachine != nil && virtualMachine?.state != .stopped
                    && virtualMachine?.state != .error)
            stoppedView.refresh(canStart: canStart, canConfigure: canConfigure)
        }
        if closeWhenStopped, !isActive {
            closeWhenStopped = false
            exitEntireDisplayIfNeeded()
            window.close()
        }
        stateDidChange?()
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: identifier, code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
