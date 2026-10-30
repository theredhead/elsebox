import AppKit
import UniformTypeIdentifiers

/// Routes application events and commands between the library, session registry, menus and import operations.
/// Feature-specific state belongs to those owners so this delegate remains application-level orchestration.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let menus = ApplicationMenus()
    private let library: VMLibrary
    private let libraryWindow = LibraryWindowController()
    private lazy var registry = VMSessionRegistry(library: library, window: libraryWindow)

    private var sessions: [UUID: VMSessionController] { registry.sessions }

    private var activeSession: VMSessionController? {
        get { registry.activeSession }
        set { registry.activeSession = newValue }
    }

    private let migration = LibraryMigrationController()

    private var working: Bool { migration.isWorking }

    private var registryReady = false
    private var pendingOpenURLs: [URL] = []
    private let artwork = ApplicationArtwork()

    init(library: VMLibrary = VMLibrary()) {
        self.library = library
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        connectMenus()
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
        NSApp.applicationIconImage = artwork.icon
    }

    @objc private func showAbout(_ sender: Any?) { artwork.showAbout() }

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
        registry.didFail = { [weak self] in self?.report($0) }
        registry.isBusy = { [weak self] in self?.working ?? true }
        registry.stateDidChange = { [weak self] in self?.reload() }
        registry.activeChanged = { [weak self] in self?.updateMenus() }
        registry.libraryActivated = { [weak self] in
            self?.pruneRegistry()
            self?.updateMenus()
        }
        registry.bind()
        libraryWindow.onNew = { [weak self] in self?.newVM(nil) }
        libraryWindow.onRemove = { [weak self] in self?.remove($0) }
    }

    private func session(for bundle: VMBundle) -> VMSessionController { registry.session(for: bundle) }

    private func connectMenus() {
        menus.onCommand = { [weak self] in self?.perform($0) }
        menus.canPerform = { [weak self] in self?.canPerform($0) ?? false }
        menus.install()
    }

    private func updateMenus() { menus.update(activeSession: activeSession) }

    private func perform(_ command: ApplicationCommand) {
        switch command {
        case .about: showAbout(nil)
        case .configure: configureVM(nil)
        case .newVM: newVM(nil)
        case .openVM: openVM(nil)
        case .showLibrary: showLibrary(nil)
        case .importPrevious: importPreviousVM(nil)
        case .toggleStatus: toggleStatus(nil)
        case .toggleEntireDisplay: toggleEntireDisplay(nil)
        case .toggleFullScreen: toggleFullScreen(nil)
        case .start: startVM(nil)
        case .startHeadless: startHeadlessVM(nil)
        case .shutDown: shutDownVM(nil)
        case .forceStop: forceStopVM(nil)
        case .bootFromDisk: bootFromDisk(nil)
        }
    }

    private func canPerform(_ command: ApplicationCommand) -> Bool {
        switch command {
        case .shutDown: return menuSession?.canShutDown == true
        case .forceStop: return menuSession?.canForceStop == true
        case .toggleStatus:
            return activeSession?.canConfigure == true
        case .toggleEntireDisplay, .toggleFullScreen:
            return activeSession != nil
        case .start, .startHeadless:
            return !working
                && (activeSession?.canStart ?? libraryWindow.selected.map {
                    sessions[$0.id]?.canStart ?? InstallerPreparation.canStart(bundle: $0)
                } ?? false)
        case .configure:
            return !working
                && (activeSession?.canConfigure ?? libraryWindow.selected.map {
                    sessions[$0.id]?.canConfigure ?? true
                } ?? false)
        case .bootFromDisk:
            if let activeSession {
                return activeSession.bundle.distribution.usesEFI && activeSession.canStart
            }
            return libraryWindow.selected.map {
                $0.distribution.usesEFI
                    && (sessions[$0.id]?.canStart ?? InstallerPreparation.canStart(bundle: $0))
            } ?? false
        case .newVM, .openVM, .importPrevious:
            return registryReady && !working
        default: return true
        }
    }

    private func reload(select id: UUID? = nil) {
        artwork.apply(to: library.machines)
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
        migration.messageDidChange = { [weak self] in self?.libraryWindow.setMessage($0) }
        migration.didFail = { [weak self] in self?.report($0) }
        migration.didFinish = { [weak self] in
            self?.reload()
            self?.openPendingBundles()
        }
        migration.migrate(library: library)
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
            registry.remove(bundle.id)
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
