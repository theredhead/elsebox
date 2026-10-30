import AppKit
import UniformTypeIdentifiers
import Virtualization

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
    private var working = false
    private var registryReady = false
    private var pendingOpenURLs: [URL] = []
    private var preparingBundleID: UUID?

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
                migratePreviousVM()
            } else {
                libraryWindow.setMessage(
                    "Close the older VirtualMac instance before importing its previous VM.")
                openPendingBundles()
            }
            reload()
        } catch { report(error) }
    }

    private func connectLibrary() {
        libraryWindow.state = { [weak self] id in
            if self?.preparingBundleID == id { return "Preparing media…" }
            return self?.sessions[id]?.stateLabel ?? "Stopped"
        }
        libraryWindow.canStart = { [weak self] id in
            !(self?.working ?? true) && (self?.sessions[id]?.canStart ?? true)
        }
        libraryWindow.canConfigure = { [weak self] id in
            !(self?.working ?? true) && (self?.sessions[id]?.canConfigure ?? true)
        }
        libraryWindow.onNew = { [weak self] in self?.newVM(nil) }
        libraryWindow.onOpen = { [weak self] in self?.openVM(nil) }
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
        session.libraryPreparing = preparingBundleID == bundle.id
        sessions[bundle.id] = session
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
        configureItem = add("Configure…", #selector(configureVM(_:)), to: vm)
        _ = add("Boot from Startup Disk", #selector(bootFromDisk(_:)), to: vm)
        let devices = submenu("Devices")
        disksItem = NSMenuItem(title: "Disks", action: nil, keyEquivalent: "")
        devices.addItem(disksItem)
        NSApp.mainMenu = menu
        updateMenus()
    }

    private func updateMenus() {
        statusItem.state = activeSession?.statusBarVisible == true ? .on : .off
        entireDisplayItem.state = activeSession?.entireDisplay == true ? .on : .off
        nativeFullScreenItem.title =
            activeSession?.nativeFullScreen == true ? "Exit Full Screen" : "Enter Full Screen"
        if let activeSession {
            disksItem.submenu = activeSession.disksMenu
        } else {
            let menu = NSMenu(title: "Disks")
            let hint = menu.addItem(
                withTitle: "Open a VM window to manage its disks", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            disksItem.submenu = menu
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleStatus(_:)):
            return activeSession?.canConfigure == true
        case #selector(toggleEntireDisplay(_:)), #selector(toggleFullScreen(_:)):
            return activeSession != nil
        case #selector(startVM(_:)):
            return !working
                && (activeSession?.canStart ?? libraryWindow.selected.map {
                    sessions[$0.id]?.canStart ?? true
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
                $0.distribution.usesEFI && (sessions[$0.id]?.canStart ?? true)
            } ?? false
        case #selector(newVM(_:)), #selector(openVM(_:)), #selector(importPreviousVM(_:)):
            return registryReady && !working
        default: return true
        }
    }

    private func reload(select id: UUID? = nil) {
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
        let alert = NSAlert()
        alert.messageText = "New Virtual Machine"
        let view = NewVMOptionsView()
        alert.accessoryView = view
        alert.addButton(withTitle: "Create…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = view.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let size = Int(view.capacity.stringValue), (8...4096).contains(size) else {
            report(settingsError("Enter a name and a disk capacity from 8 to 4096 GB."))
            return
        }
        let preset = view.preset
        var windowsSetup: WindowsSetupView?
        if preset.distribution == .windows {
            let setup = NSAlert()
            setup.messageText = "Windows Setup"
            let options = WindowsSetupView()
            setup.accessoryView = options
            setup.addButton(withTitle: "Continue")
            setup.addButton(withTitle: "Cancel")
            while true {
                guard setup.runModal() == .alertFirstButtonReturn else { return }
                do {
                    try options.validate()
                    break
                } catch { report(error) }
            }
            windowsSetup = options
        }
        var localISO: URL?
        if !preset.distribution.hasAutomaticInstaller {
            let picker = NSOpenPanel()
            picker.title = preset.distribution.installerSelectionTitle
            picker.message = preset.distribution.installerSelectionMessage
            picker.prompt = "Choose Installer"
            picker.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
            guard picker.runModal() == .OK, let source = picker.url else { return }
            localISO = source
        }
        let panel = NSSavePanel()
        panel.title = "Create .asvm Bundle"
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".asvm"
        panel.directoryURL = library.defaultLocation
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [
            UTType(exportedAs: "nl.theredhead.virtualmac.asvm", conformingTo: .package)
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bundle = try VMBundle.create(
                at: url, name: title, capacityGB: size, preset: preset, mediaCache: library.mediaCache)
            if let windowsSetup {
                do {
                    var settings = try bundle.resolvedSettings()
                    try windowsSetup.apply(to: &settings, id: bundle.id)
                    try bundle.save(settings)
                } catch {
                    try? WindowsSetupSecret.remove(for: bundle.id)
                    try? FileManager.default.removeItem(at: bundle.url)
                    throw error
                }
            }
            _ = try library.register(bundle.url)
            libraryWindow.showWindow()
            reload(select: bundle.id)
            working = true
            preparingBundleID = bundle.id
            reload(select: bundle.id)
            Task {
                defer {
                    working = false
                    preparingBundleID = nil
                    sessions[bundle.id]?.libraryPreparing = false
                    reload(select: bundle.id)
                    openPendingBundles()
                }
                do {
                    let lease = try VMLease(directory: bundle.url)
                    defer { withExtendedLifetime(lease) {} }
                    var settings = try bundle.resolvedSettings()
                    if let localISO {
                        settings.installationMediaPath = localISO.path
                        settings.bootFromInstaller = true
                    }
                    try await InstallerPreparation.save(bundle: bundle, settings: settings)
                    libraryWindow.setMessage("Created \(title).")
                    session(for: bundle).showWindow()
                } catch is CancellationError {
                    libraryWindow.setMessage("Installer download cancelled.")
                } catch {
                    libraryWindow.setMessage("Installer download failed. Configure the VM to retry.")
                    report(error)
                }
            }
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
                libraryWindow.setMessage(
                    "VM Library"
                )
            } catch {
                libraryWindow.setMessage(
                    "Previous VM import deferred. Use File → Import Previous VM after shutting down the old VM."
                )
                report(error)
            }
        }
    }

    private func remove(_ bundle: VMBundle) {
        guard !working, sessions[bundle.id]?.isActive != true else { return }
        do {
            try library.remove(bundle.id)
            sessions.removeValue(forKey: bundle.id)?.closeWindow()
            libraryWindow.setMessage(
                "Removed \(bundle.name) from the library. Its .asvm bundle is still on disk.")
            reload()
        } catch { report(error) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !working, !sessions.values.contains(where: { $0.isActive }) else {
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
