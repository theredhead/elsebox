import AppKit
import Virtualization

/// Binds one guest's execution to its reusable console and the library's controls/observers.
/// Owns presentation intent (including headless mode), while VMExecutionController owns hardware and its lease.
@MainActor
final class VMSessionController: NSObject {
    let bundle: VMBundle
    let disksMenu = NSMenu(title: "Disks")

    private let execution: VMExecutionController
    private let console: VMConsoleController
    private let displayFitter = VMDisplayFitter()
    private lazy var thumbnails = VMThumbnailController(bundle: bundle)
    private var disksController: AnyObject?
    private var opensVMWindowOnStart = true
    private var closeWhenStopped = false

    var stateDidChange: (() -> Void)?
    var networkDidChange: (() -> Void)?
    var didActivate: (() -> Void)?
    var willUseEntireDisplay: (() -> Void)?

    var isActive: Bool { execution.isActive }

    var stateLabel: String { execution.stateLabel }

    var canStart: Bool { execution.canStart }

    var canConfigure: Bool { execution.canConfigure }

    var canShutDown: Bool { execution.canShutDown }

    var canForceStop: Bool { execution.canForceStop }

    var isPreparingMedia: Bool { execution.isPreparingMedia }

    var hasRunningGuest: Bool { execution.hasRunningGuest }

    var statusBarVisible: Bool { console.content.statusBarVisible }

    var entireDisplay: Bool { console.presentation.usesEntireDisplay }

    var nativeFullScreen: Bool { console.window.styleMask.contains(.fullScreen) }

    var networkSnapshot: VMNetworkSnapshot? { execution.network.snapshot }

    var networkIsLive: Bool { execution.network.isLive }

    var previewMachine: VZVirtualMachine? {
        guard let machine = execution.machine, machine.state == .running || machine.state == .paused else {
            return nil
        }
        return machine
    }

    var activityCounters: VMActivityCounters? {
        guard let machine = execution.machine, machine.state == .running else { return nil }
        return VMHostMetricsSource.read(machine)
    }

    init(bundle: VMBundle) {
        self.bundle = bundle
        execution = VMExecutionController(bundle: bundle)
        console = VMConsoleController(bundle: bundle)
        super.init()
        connectExecution()
        connectConsole()
        configureDevices()
    }

    private func connectExecution() {
        execution.stateDidChange = { [weak self] in self?.refresh() }
        execution.statusDidChange = { [weak self] in self?.console.content.statusText = $0 }
        execution.runtimeDidChange = { [weak self] in self?.attachRuntime($0) }
        execution.runtimeDidStop = { [weak self] in self?.stopPresentation() }
        execution.restartRequested = { [weak self] in
            guard let self else { return }
            self.startVirtualMachine(headless: !self.opensVMWindowOnStart)
        }
        execution.didFail = { [weak self] in
            self?.closeWhenStopped = false
            NSAlert(error: $0).runModal()
        }
        execution.devicesBusy = { [weak self] in self?.devicesBusy == true }
        execution.network.didChange = { [weak self] in self?.networkDidChange?() }
    }

    private func connectConsole() {
        console.didActivate = { [weak self] in self?.didActivate?() }
        console.shouldClose = { [weak self] in self?.shouldCloseConsole() ?? true }
        console.didClose = { [weak self] in self?.opensVMWindowOnStart = false }
        console.content.onStart = { [weak self] in self?.startVirtualMachine() }
        console.content.onConfigure = { [weak self] in self?.showPreferences() }
        console.content.vmView.viewportDidChange = { [weak self] in self?.scheduleDisplayFit() }
        console.presentation.didChange = { [weak self] in self?.refresh() }
        console.presentation.viewportDidChange = { [weak self] in self?.scheduleDisplayFit() }
        console.presentation.willEnterEntireDisplay = { [weak self] in self?.willUseEntireDisplay?() }
        displayFitter.didFail = { [weak self] in
            self?.console.content.statusText = "Could not fit guest display: \($0.localizedDescription)"
        }
    }

    func showWindow() {
        opensVMWindowOnStart = true
        console.show()
    }

    func closeWindow() { console.close() }

    func startVirtualMachine(_ sender: Any? = nil, headless: Bool? = nil) {
        guard canStart else { return }
        do {
            let preferences = try bundle.resolvedSettings()
            let settings = try VMBootSettings.make(
                preferences: preferences, distribution: bundle.distribution,
                hostAspectRatio: console.hostAspectRatio)
            opensVMWindowOnStart = !(headless ?? preferences.startHeadless ?? false)
            closeWhenStopped = false
            if opensVMWindowOnStart { console.show() } else { console.hide() }
            execution.start(settings: settings)
        } catch { NSAlert(error: error).runModal() }
    }

    func shutDown() { execution.shutDown() }

    func forceStop(closeAfterStopping: Bool = false) {
        guard canForceStop, VMCloseConfirmation.confirmForceStop(name: bundle.name) else { return }
        closeWhenStopped = closeAfterStopping
        execution.forceStop()
    }

    private func shouldCloseConsole() -> Bool {
        guard isActive else {
            exitEntireDisplayIfNeeded()
            return true
        }
        switch VMCloseConfirmation.choose(
            name: bundle.name, canShutDown: canShutDown, canForceStop: canForceStop)
        {
        case .headless:
            opensVMWindowOnStart = false
            exitEntireDisplayIfNeeded()
            return true
        case .shutDown:
            closeWhenStopped = true
            shutDown()
        case .forceStop:
            forceStop(closeAfterStopping: true)
        case .cancel: break
        }
        return false
    }

    func showPreferences(_ sender: Any? = nil) {
        guard canConfigure else { return }
        do {
            if try VMSettingsController.edit(bundle: bundle, hostAspectRatio: console.hostAspectRatio) {
                refresh()
            }
        } catch { NSAlert(error: error).runModal() }
    }

    func toggleStatusBar(_ sender: Any? = nil) {
        guard !execution.isFinalizing else { return }
        do {
            var settings = try bundle.resolvedSettings()
            settings.showsStatusBar = !statusBarVisible
            try bundle.save(settings)
            console.content.setStatusBarVisible(!statusBarVisible)
            refresh()
            scheduleDisplayFit()
        } catch { NSAlert(error: error).runModal() }
    }

    func toggleEntireDisplay(_ sender: Any? = nil) { console.presentation.toggleEntireDisplay() }

    func toggleNativeFullScreen(_ sender: Any? = nil) { console.presentation.toggleNativeFullScreen() }

    func exitEntireDisplayIfNeeded() { console.presentation.exitEntireDisplayIfNeeded() }

    private func attachRuntime(_ runtime: VMRuntime) {
        console.content.vmView.usesUSBMouse =
            bundle.distribution.usesEFI || runtime.settings.useMacTrackpad != true
        console.content.vmView.virtualMachine = runtime.machine
        console.content.activityView.start(allocatedMemory: runtime.configuration.memorySize) {
            [weak machine = runtime.machine] in
            guard let machine, machine.state == .running || machine.state == .starting else { return nil }
            return VMHostMetricsSource.read(machine)
        }
        updateDeviceMenu()
    }

    private func stopPresentation() {
        displayFitter.cancel()
        console.content.activityView.stop()
        console.content.vmView.virtualMachine = nil
    }

    private func scheduleDisplayFit() {
        displayFitter.schedule(
            machine: execution.machine, resources: execution.runtime?.settings,
            viewport: console.content.vmView.bounds.size, entireDisplay: entireDisplay || nativeFullScreen)
    }

    private func refresh() {
        thumbnails.update(view: console.content.vmView, running: hasRunningGuest)
        let stopped =
            execution.machine == nil || execution.machine?.state == .stopped
            || execution.machine?.state == .error
        console.content.updateStoppedOverlay(
            visible: !execution.isBooting && stopped, canStart: canStart, canConfigure: canConfigure)
        if execution.machine == nil { console.content.vmView.virtualMachine = nil }
        if closeWhenStopped, !isActive {
            closeWhenStopped = false
            exitEntireDisplayIfNeeded()
            console.close()
        }
        updateDeviceMenu()
        scheduleDisplayFit()
        stateDidChange?()
    }

    private func configureDevices() {
        if #available(macOS 15.0, *) {
            let controller = RemovableDisksController(menu: disksMenu)
            controller.stateDidChange = { [weak self] in
                self?.refresh()
                self?.updateDeviceMenu()
            }
            controller.guestToolsURL = bundle.distribution == .windows ? BundledGuestTools.imageURL : nil
            controller.installationMediaDidEject = { [weak self] in try self?.releaseInstallationMedia() }
            disksController = controller
            console.content.vmView.canMountImages = { [weak controller] in controller?.canMountImages == true
            }
            console.content.vmView.mountImages = { [weak controller] in
                controller?.mountDroppedImages($0) ?? false
            }
        } else {
            let item = disksMenu.addItem(
                withTitle: "Live disks require macOS Sequoia 15 or later", action: nil, keyEquivalent: "")
            item.isEnabled = false
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
            bootFromStartupDisk()
        }
    }

    func bootFromStartupDisk() {
        guard canStart, bundle.distribution.usesEFI else { return }
        do {
            try releaseInstallationMedia()
            refresh()
        } catch { NSAlert(error: error).runModal() }
    }

    private func releaseInstallationMedia() throws { try execution.releaseInstallationMedia() }

    private var devicesBusy: Bool {
        if #available(macOS 15.0, *), let devices = disksController as? RemovableDisksController {
            return devices.operationInProgress
        }
        return false
    }

    private func updateDeviceMenu() {
        if #available(macOS 15.0, *), let devices = disksController as? RemovableDisksController {
            devices.update(
                machine: execution.machine, bootDisk: execution.runtime?.bootDisk,
                installationMedia: execution.installationMedia, busy: execution.controlsBusy)
        }
    }
}
