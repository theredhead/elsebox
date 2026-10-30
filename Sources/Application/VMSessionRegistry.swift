import Foundation

/// Retains independent sessions and projects their state/actions into the library; it does not own app menus or migration.
@MainActor
final class VMSessionRegistry {
    private let library: VMLibrary
    private let libraryWindow: LibraryWindowController
    private(set) var sessions: [UUID: VMSessionController] = [:]
    weak var activeSession: VMSessionController?

    var isBusy: () -> Bool = { false }

    var didFail: ((Error) -> Void)?
    var stateDidChange: (() -> Void)?
    var activeChanged: (() -> Void)?
    var libraryActivated: (() -> Void)?

    init(library: VMLibrary, window: LibraryWindowController) {
        self.library = library
        libraryWindow = window
    }

    func remove(_ id: UUID) { sessions.removeValue(forKey: id)?.closeWindow() }

    func bind() {
        bindDownloads()
        bindNetwork()
        bindDevices()
        bindState()
        bindActions()
    }

    private func bindDownloads() {
        InstallerPreparation.stateDidChange = { [weak self] in self?.stateDidChange?() }
        InstallerPreparation.progressDidChange = { [weak self] in self?.libraryWindow.refreshDetails() }
        libraryWindow.downloadState = { InstallerPreparation.state(for: $0) }
        libraryWindow.onDownloadAction = { [weak self] bundle in
            if InstallerPreparation.isPreparing(bundle.id) {
                InstallerPreparation.cancel(bundle.id)
            } else {
                do {
                    try InstallerPreparation.begin(bundle: bundle, settings: bundle.resolvedSettings())
                } catch { self?.didFail?(error) }
            }
        }
        libraryWindow.mediaURL = library.mediaCache.root
    }

    private func bindNetwork() {
        libraryWindow.networkInfo = { [weak self] id in
            guard let self else { return (nil, false) }
            if let session = self.sessions[id] { return (session.networkSnapshot, session.networkIsLive) }
            guard let bundle = self.library.machines.first(where: { $0.id == id }) else {
                return (nil, false)
            }
            return (VMNetworkSnapshotStore.read(from: bundle.url), false)
        }
    }

    private func bindDevices() {
        libraryWindow.removableMedia = { [weak self] id in
            guard let self, let bundle = self.library.machines.first(where: { $0.id == id }) else {
                return []
            }
            return self.sessions[id]?.removableMedia
                ?? VMSessionController.configuredInstallationMedia(bundle: bundle, canEject: !self.isBusy())
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
            if self.isBusy() || InstallerPreparation.hasActiveDownloads
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
    }

    private func bindState() {
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
            !(self?.isBusy() ?? true) && !InstallerPreparation.isPreparing(id)
                && (self?.sessions[id]?.canStart ?? self?.library.machines.first(where: { $0.id == id })
                    .map { InstallerPreparation.canStart(bundle: $0) } ?? false)
        }
        libraryWindow.canRemove = { [weak self] id in
            !(self?.isBusy() ?? true) && !InstallerPreparation.isPreparing(id)
                && self?.sessions[id]?.isActive != true
        }
        libraryWindow.canConfigure = { [weak self] id in
            !(self?.isBusy() ?? true) && (self?.sessions[id]?.canConfigure ?? true)
        }
        libraryWindow.previewMachine = { [weak self] id in self?.sessions[id]?.previewMachine }
    }

    private func bindActions() {
        libraryWindow.onStart = { [weak self] vm in
            guard let self, !self.isBusy() else { return }
            self.session(for: vm).startVirtualMachine()
        }
        libraryWindow.onConfigure = { [weak self] vm in
            guard let self, !self.isBusy() else { return }
            self.session(for: vm).showPreferences()
        }
        libraryWindow.onShow = { [weak self] vm in self?.session(for: vm).showWindow() }
        libraryWindow.onActivate = { [weak self] in
            self?.activeSession = nil
            self?.libraryActivated?()
        }
        libraryWindow.onSelection = { [weak self] in self?.activeChanged?() }
    }

    func session(for bundle: VMBundle) -> VMSessionController {
        if let session = sessions[bundle.id] {
            if session.bundle.url == bundle.url || session.isActive { return session }
            session.closeWindow()
        }

        let session = VMSessionController(bundle: bundle)
        sessions[bundle.id] = session
        session.networkDidChange = { [weak self] in self?.libraryWindow.refreshDetails() }
        session.stateDidChange = { [weak self] in self?.stateDidChange?() }
        session.didActivate = { [weak self, weak session] in
            self?.activeSession = session
            self?.activeChanged?()
        }
        session.willUseEntireDisplay = { [weak self, weak session] in
            guard let self else { return }
            for peer in self.sessions.values where peer !== session { peer.exitEntireDisplayIfNeeded() }
        }
        return session
    }
}
