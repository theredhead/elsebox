import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let library: VMLibrary
    private let libraryWindow = LibraryWindowController()
    private var sessions: [UUID: VMSessionController] = [:]
    private weak var activeSession: VMSessionController?
    private var startItem: NSMenuItem!
    private var configureItem: NSMenuItem!
    private var statusItem: NSMenuItem!
    private var entireDisplayItem: NSMenuItem!
    private var nativeFullScreenItem: NSMenuItem!
    private var disksItem: NSMenuItem!
    private var devicesItem: NSMenuItem!
    private var working = false
    private var registryReady = false
    private var pendingOpenURLs: [URL] = []
    private var iconAppliedURLs: Set<URL> = []

    init(library: VMLibrary = VMLibrary()) {
        self.library = library
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeMenus()
        connectLibrary()
        libraryWindow.showWindow()
        NSApp.activate(ignoringOtherApps: true)
        do {
            try library.load()
            registryReady = true
            // The old process has no .asvm lease, so don't migrate underneath it.
            let otherInstance =
                library.root == VMDiskStore.directory
                && NSRunningApplication.runningApplications(withBundleIdentifier: "nl.theredhead.virtualmac")
                    .contains { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if !otherInstance {
                try? BundledGuestTools.removeLegacyCacheCopy(
                    cache: library.mediaCache, machines: library.machines)
                migratePreviousVM()
            } else {
                libraryWindow.setMessage(
                    "Close the older VirtualMac instance before importing its previous VM.")
                openPendingBundles()
            }
            reload()
            if !otherInstance { resumeDownloads() }
        } catch { report(error) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.applicationIconImage = applicationIcon
    }

    private var applicationIcon: NSImage? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns"))
    }

    @objc private func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © theredhead 2026"
        ]
        if let icon = applicationIcon { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private func resumeDownloads() {
        for bundle in library.machines where bundle.distribution.hasAutomaticInstaller {
            do {
                let settings = try bundle.resolvedSettings()
                if InstallerPreparation.state(for: bundle.id) == nil,
                    InstallerMediaService.needsDownload(bundle: bundle, settings: settings)
                {
                    try InstallerPreparation.begin(bundle: bundle, settings: settings)
                }
            } catch { libraryWindow.setMessage(error.localizedDescription) }
        }
    }

    private func connectLibrary() {
        InstallerPreparation.stateDidChange = { [weak self] in self?.reload() }
        InstallerPreparation.progressDidChange = { [weak self] in self?.libraryWindow.refreshDetails() }
        libraryWindow.downloadState = { InstallerPreparation.state(for: $0) }
        libraryWindow.onDownloadAction = { [weak self] bundle in
            if InstallerPreparation.isPreparing(bundle.id) {
                InstallerPreparation.cancel(bundle.id)
            } else {
                do {
                    try InstallerPreparation.begin(bundle: bundle, settings: bundle.resolvedSettings())
                } catch { self?.report(error) }
            }
        }
        libraryWindow.mediaURL = library.mediaCache.root
        libraryWindow.networkInfo = { [weak self] id in
            guard let self else { return (nil, false) }
            if let session = self.sessions[id] { return (session.networkSnapshot, session.networkIsLive) }
            guard let bundle = self.library.machines.first(where: { $0.id == id }) else {
                return (nil, false)
            }
            return (VMNetworkSnapshotStore.read(from: bundle.url), false)
        }
        libraryWindow.removableMedia = { [weak self] id in
            guard let self, let bundle = self.library.machines.first(where: { $0.id == id }) else {
                return []
            }
            return self.sessions[id]?.removableMedia
                ?? VMSessionController.configuredInstallationMedia(bundle: bundle, canEject: !self.working)
        }
        libraryWindow.canShutDown = { [weak self] in self?.sessions[$0]?.canShutDown == true }
        libraryWindow.canForceStop = { [weak self] in self?.sessions[$0]?.canForceStop == true }
        libraryWindow.onShutDown = { [weak self] in self?.sessions[$0.id]?.shutDown() }
        libraryWindow.onForceStop = { [weak self] in self?.sessions[$0.id]?.forceStop() }
        libraryWindow.onEjectMedia = { [weak self] bundle, id in
            self?.session(for: bundle).ejectRemovableMedia(id: id)
        }
        libraryWindow.mediaCleanupRestriction = { [weak self] url in
            guard let self else { return "Library unavailable" }
            if self.working || InstallerPreparation.hasActiveDownloads
                || self.sessions.values.contains(where: { $0.isPreparingMedia })
            {
                return "Media preparation in progress"
            }
            for bundle in self.library.machines {
                guard let settings = try? bundle.resolvedSettings() else { return "VM settings unavailable" }
                let paths = [
                    settings.restoreImagePath, settings.installationMediaPath, settings.driverMediaPath,
                ]
                if paths.compactMap({ $0 }).contains(where: {
                    URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
                        == url.standardizedFileURL.resolvingSymlinksInPath()
                }) {
                    return "Used by \(bundle.name)"
                }
            }
            return nil
        }
        libraryWindow.overviewActivity = { [weak self] in
            let running = self?.sessions.values.filter { $0.hasRunningGuest } ?? []
            return VMLibraryActivityInput(
                runningCount: running.count,
                counters: running.compactMap { $0.activityCounters })
        }
        libraryWindow.state = { [weak self] id in
            if InstallerPreparation.isPreparing(id) { return "Downloading…" }
            if InstallerPreparation.state(for: id)?.failed == true { return "Download failed" }
            return self?.sessions[id]?.stateLabel ?? "Stopped"
        }
        libraryWindow.canStart = { [weak self] id in
            !(self?.working ?? true) && !InstallerPreparation.isPreparing(id)
                && (self?.sessions[id]?.canStart ?? self?.library.machines.first(where: { $0.id == id })
                    .map { InstallerPreparation.canStart(bundle: $0) } ?? false)
        }
        libraryWindow.canRemove = { [weak self] id in
            !(self?.working ?? true) && !InstallerPreparation.isPreparing(id)
                && self?.sessions[id]?.isActive != true
        }
        libraryWindow.canConfigure = { [weak self] id in
            !(self?.working ?? true) && (self?.sessions[id]?.canConfigure ?? true)
        }
        libraryWindow.onNew = { [weak self] in self?.newVM(nil) }
        libraryWindow.previewMachine = { [weak self] id in self?.sessions[id]?.previewMachine }
        libraryWindow.onStart = { [weak self] vm in
            guard let self, !self.working else { return }
            self.session(for: vm).startVirtualMachine()
        }
        libraryWindow.onConfigure = { [weak self] vm in
            guard let self, !self.working else { return }
            self.session(for: vm).showPreferences()
        }
        libraryWindow.onShow = { [weak self] vm in self?.session(for: vm).showWindow() }
        libraryWindow.onRemove = { [weak self] vm in self?.remove(vm) }
        libraryWindow.onActivate = { [weak self] in
            self?.activeSession = nil
            self?.pruneRegistry()
            self?.updateMenus()
        }
        libraryWindow.onSelection = { [weak self] in self?.updateMenus() }
    }

    private func session(for bundle: VMBundle) -> VMSessionController {
        if let session = sessions[bundle.id] {
            if session.bundle.url == bundle.url || session.isActive { return session }
            session.closeWindow()
        }
        let session = VMSessionController(bundle: bundle)
        sessions[bundle.id] = session
        session.networkDidChange = { [weak self] in self?.libraryWindow.refreshDetails() }
        session.stateDidChange = { [weak self] in self?.reload() }
        session.didActivate = { [weak self, weak session] in
            self?.activeSession = session
            self?.updateMenus()
        }
        session.willUseEntireDisplay = { [weak self, weak session] in
            guard let self else { return }
            for peer in self.sessions.values where peer !== session { peer.exitEntireDisplayIfNeeded() }
        }
        return session
    }

    private func makeMenus() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            menu.addItem(item)
            return submenu
        }
        func add(_ title: String, _ action: Selector, _ key: String = "", to menu: NSMenu) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        let app = submenu("VirtualMac")
        let about = app.addItem(
            withTitle: "About VirtualMac", action: #selector(showAbout(_:)),
            keyEquivalent: "")
        about.target = self
        app.addItem(.separator())
        _ = add("Configure Virtual Machine…", #selector(configureVM(_:)), ",", to: app)
        app.addItem(.separator())
        app.addItem(
            withTitle: "Quit VirtualMac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let file = submenu("File")
        _ = add("New Virtual Machine…", #selector(newVM(_:)), "n", to: file)
        _ = add("Open .asvm…", #selector(openVM(_:)), "o", to: file)
        _ = add("Show VM Library", #selector(showLibrary(_:)), "l", to: file)
        _ = add("Import Previous VM…", #selector(importPreviousVM(_:)), to: file)
        let view = submenu("View")
        statusItem = add("Show Status Bar", #selector(toggleStatus(_:)), to: view)
        entireDisplayItem = add("Use Entire Display", #selector(toggleEntireDisplay(_:)), to: view)
        nativeFullScreenItem = add("Enter Full Screen", #selector(toggleFullScreen(_:)), "f", to: view)
        nativeFullScreenItem.keyEquivalentModifierMask = [.control, .command]
        let vm = submenu("Virtual Machine")
        startItem = add("Start Virtual Machine", #selector(startVM(_:)), "r", to: vm)
        let headless = add("Start Headless", #selector(startHeadlessVM(_:)), "r", to: vm)
        headless.keyEquivalentModifierMask = [.option, .command]
        _ = add("Shut Down", #selector(shutDownVM(_:)), to: vm)
        _ = add("Force Stop…", #selector(forceStopVM(_:)), to: vm)
        vm.addItem(.separator())
        configureItem = add("Configure…", #selector(configureVM(_:)), to: vm)
        _ = add("Boot from Startup Disk", #selector(bootFromDisk(_:)), to: vm)
        let devices = submenu("Devices")
        devicesItem = menu.items.last
        disksItem = NSMenuItem(title: "Disks", action: nil, keyEquivalent: "")
        devices.addItem(disksItem)
        let windows = submenu("Window")
        let minimize = windows.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        minimize.target = nil
        let zoom = windows.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        zoom.target = nil
        windows.addItem(.separator())
        _ = add("VM Library", #selector(showLibrary(_:)), "0", to: windows)
        windows.addItem(.separator())
        let bringAll = windows.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")
        bringAll.target = nil
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
        updateMenus()
    }

    private func updateMenus() {
        statusItem.state = activeSession?.statusBarVisible == true ? .on : .off
        entireDisplayItem.state = activeSession?.entireDisplay == true ? .on : .off
        nativeFullScreenItem.title =
            activeSession?.nativeFullScreen == true ? "Exit Full Screen" : "Enter Full Screen"
        let runningSession = activeSession.flatMap { $0.hasRunningGuest ? $0 : nil }
        devicesItem.isHidden = runningSession == nil
        disksItem.submenu = runningSession?.disksMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(shutDownVM(_:)): return menuSession?.canShutDown == true
        case #selector(forceStopVM(_:)): return menuSession?.canForceStop == true
        case #selector(toggleStatus(_:)):
            return activeSession?.canConfigure == true
        case #selector(toggleEntireDisplay(_:)), #selector(toggleFullScreen(_:)):
            return activeSession != nil
        case #selector(startVM(_:)), #selector(startHeadlessVM(_:)):
            return !working
                && (activeSession?.canStart ?? libraryWindow.selected.map {
                    sessions[$0.id]?.canStart ?? InstallerPreparation.canStart(bundle: $0)
                } ?? false)
        case #selector(configureVM(_:)):
            return !working
                && (activeSession?.canConfigure ?? libraryWindow.selected.map {
                    sessions[$0.id]?.canConfigure ?? true
                } ?? false)
        case #selector(bootFromDisk(_:)):
            if let activeSession {
                return activeSession.bundle.distribution.usesEFI && activeSession.canStart
            }
            return libraryWindow.selected.map {
                $0.distribution.usesEFI
                    && (sessions[$0.id]?.canStart ?? InstallerPreparation.canStart(bundle: $0))
            } ?? false
        case #selector(newVM(_:)), #selector(openVM(_:)), #selector(importPreviousVM(_:)):
            return registryReady && !working
        default: return true
        }
    }

    private func reload(select id: UUID? = nil) {
        if let icon = applicationIcon {
            for machine in library.machines where !iconAppliedURLs.contains(machine.url) {
                if NSWorkspace.shared.setIcon(icon, forFile: machine.url.path, options: []) {
                    iconAppliedURLs.insert(machine.url)
                }
            }
        }
        libraryWindow.reload(library.machines, select: id)
        updateMenus()
    }

    private func pruneRegistry() {
        guard registryReady, !working else { return }
        do {
            try library.refresh()
            reload()
        } catch { report(error) }
    }

    @objc private func showLibrary(_ sender: Any?) {
        libraryWindow.showWindow()
        pruneRegistry()
    }
    @objc private func startVM(_ sender: Any?) {
        if let activeSession {
            activeSession.startVirtualMachine()
        } else if let vm = libraryWindow.selected {
            session(for: vm).startVirtualMachine()
        }
    }
    @objc private func startHeadlessVM(_ sender: Any?) {
        guard !working else { return }
        if let activeSession {
            activeSession.startVirtualMachine(headless: true)
        } else if let vm = libraryWindow.selected {
            session(for: vm).startVirtualMachine(headless: true)
        }
    }

    private var menuSession: VMSessionController? {
        activeSession ?? libraryWindow.selected.flatMap { sessions[$0.id] }
    }
    @objc private func shutDownVM(_ sender: Any?) { menuSession?.shutDown() }
    @objc private func forceStopVM(_ sender: Any?) { menuSession?.forceStop() }

    @objc private func configureVM(_ sender: Any?) {
        if let activeSession {
            activeSession.showPreferences()
        } else if let vm = libraryWindow.selected {
            session(for: vm).showPreferences()
        }
    }
    @objc private func bootFromDisk(_ sender: Any?) {
        let target = activeSession ?? libraryWindow.selected.map { session(for: $0) }
        target?.bootFromStartupDisk()
    }

    @objc private func toggleStatus(_ sender: Any?) { activeSession?.toggleStatusBar() }
    @objc private func toggleEntireDisplay(_ sender: Any?) { activeSession?.toggleEntireDisplay() }
    @objc private func toggleFullScreen(_ sender: Any?) { activeSession?.toggleNativeFullScreen() }

    @objc private func newVM(_ sender: Any?) {
        guard !working else { return }
        do {
            guard
                let bundle = try NewVMController.create(
                    defaultLocation: library.defaultLocation, mediaCache: library.mediaCache)
            else { return }
            _ = try library.register(bundle.url)
            libraryWindow.showWindow()
            reload(select: bundle.id)
            try InstallerPreparation.begin(bundle: bundle, settings: bundle.resolvedSettings())
            libraryWindow.setMessage("Created \(bundle.name).")
            reload(select: bundle.id)
        } catch { report(error) }
    }

    @objc private func openVM(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Virtual Machine Bundles"
        panel.message =
            "Select one or more VirtualMac virtual machine bundles (.asvm) to add to your library."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            UTType(exportedAs: "nl.theredhead.virtualmac.asvm", conformingTo: .package)
        ]
        guard panel.runModal() == .OK else { return }
        openBundles(panel.urls)
    }

    private func openBundles(_ urls: [URL]) {
        guard registryReady, !working else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        var selected: UUID?
        for url in urls {
            do {
                let bundle = try VMBundle.open(url)
                if let existing = sessions[bundle.id], existing.isActive, existing.bundle.url != bundle.url {
                    throw settingsError("Shut down the existing session before reopening a moved VM bundle.")
                }
                selected = try library.register(url).id
            } catch { report(error) }
        }
        libraryWindow.showWindow()
        reload(select: selected)
    }

    func application(_ application: NSApplication, open urls: [URL]) { openBundles(urls) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary(nil)
        return true
    }
    @objc private func importPreviousVM(_ sender: Any?) { migratePreviousVM() }

    private func openPendingBundles() {
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        if !urls.isEmpty { openBundles(urls) }
    }

    private func migratePreviousVM() {
        guard !working else { return }
        guard
            library.root != VMDiskStore.directory
                || !NSRunningApplication.runningApplications(withBundleIdentifier: "nl.theredhead.virtualmac")
                    .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        else {
            report(settingsError("Close the older VirtualMac instance before migrating its VM."))
            return
        }
        working = true
        libraryWindow.setMessage("Checking the previous VM for migration…")
        let root = library.root
        Task {
            defer {
                working = false
                reload()
                openPendingBundles()
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let worker = VMLibrary(root: root)
                    try worker.load()
                    try worker.migrateLegacyIfNeeded(from: root)
                }.value
                try library.load()
                libraryWindow.setMessage("")
            } catch {
                libraryWindow.setMessage(
                    "Previous VM import deferred. Use File → Import Previous VM after shutting down the old VM."
                )
                report(error)
            }
        }
    }

    private func remove(_ bundle: VMBundle) {
        guard !working, !InstallerPreparation.isPreparing(bundle.id),
            sessions[bundle.id]?.isActive != true
        else { return }
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to remove this VM?"
        alert.informativeText = "\(bundle.name)\nDeleting files moves the .asvm bundle to Trash."
        alert.addButton(withTitle: "Remove from list")
        alert.addButton(withTitle: "Also delete files")
        alert.buttons[1].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        let deleteFiles = response == .alertSecondButtonReturn
        do {
            if deleteFiles {
                try FileManager.default.trashItem(at: bundle.url, resultingItemURL: nil)
            }
            try library.remove(bundle.id)
            sessions.removeValue(forKey: bundle.id)?.closeWindow()
            libraryWindow.setMessage(
                deleteFiles
                    ? "Moved \(bundle.name) to Trash."
                    : "Removed \(bundle.name) from the library. Its .asvm bundle is still on disk.")
            reload()
        } catch { report(error) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !working, !InstallerPreparation.hasActiveDownloads,
            !sessions.values.contains(where: { $0.isActive })
        else {
            report(
                settingsError(
                    "Shut down all running guests and wait for VM operations to finish before quitting."))
            return .terminateCancel
        }
        for session in sessions.values { session.exitEntireDisplayIfNeeded() }
        return .terminateNow
    }

    private func report(_ error: Error) { NSAlert(error: error).runModal() }
}
