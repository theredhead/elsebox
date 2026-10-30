import Foundation

struct InstallerPreparationState {
    var message: String
    var fraction: Double?
    var active: Bool
    var failed = false
}

/// Owns per-VM background work; only media results are merged into the latest saved settings.
@MainActor
enum InstallerPreparation {
    private final class Job {
        var state = InstallerPreparationState(message: "Preparing installer…", active: true)
        var task: Task<Void, Error>?
    }
    private static var jobs: [UUID: Job] = [:]
    static var stateDidChange: (() -> Void)?
    static var progressDidChange: (() -> Void)?

    static func state(for id: UUID) -> InstallerPreparationState? { jobs[id]?.state }
    static func isPreparing(_ id: UUID) -> Bool { jobs[id]?.state.active == true }
    static var hasActiveDownloads: Bool { jobs.values.contains { $0.state.active } }

    static func canStart(bundle: VMBundle) -> Bool {
        guard !isPreparing(bundle.id), let settings = try? bundle.resolvedSettings() else { return false }
        return !InstallerMediaService.needsDownload(bundle: bundle, settings: settings)
    }

    static func begin(
        bundle: VMBundle, settings: VMSettings, service: InstallerMediaService = InstallerMediaService()
    ) throws {
        // Commit edits now; download completion must never restore an older CPU/RAM/etc. snapshot.
        try bundle.save(settings)
        if isPreparing(bundle.id) {
            stateDidChange?()
            return
        }
        guard InstallerMediaService.needsDownload(bundle: bundle, settings: try bundle.resolvedSettings())
        else {
            jobs[bundle.id] = nil
            stateDidChange?()
            return
        }
        let job = Job()
        jobs[bundle.id] = job
        job.task = Task {
            do {
                while true {
                    let requested = try bundle.resolvedSettings()
                    let ready: VMSettings
                    do {
                        ready = try await service.prepare(bundle: bundle, settings: requested) {
                            message, fraction in
                            Task { @MainActor in
                                guard job.state.active else { return }
                                job.state.message = message
                                job.state.fraction = fraction
                                progressDidChange?()
                            }
                        }
                    } catch {
                        try Task.checkCancellation()
                        if !sameRequest(requested, try bundle.resolvedSettings()) { continue }
                        throw error
                    }
                    try Task.checkCancellation()
                    var latest = try bundle.resolvedSettings()
                    // Changed culture/media/disk: prepare the newest request before enabling power.
                    guard sameRequest(requested, latest) else { continue }
                    latest.restoreImagePath = ready.restoreImagePath
                    latest.installationMediaPath = ready.installationMediaPath
                    latest.driverMediaPath = ready.driverMediaPath
                    latest.bootFromInstaller = ready.bootFromInstaller
                    try bundle.save(latest)
                    job.state = InstallerPreparationState(message: "Ready", fraction: 1, active: false)
                    stateDidChange?()
                    return
                }
            } catch {
                job.state = InstallerPreparationState(
                    message: error is CancellationError ? "Download cancelled" : error.localizedDescription,
                    active: false, failed: true)
                stateDidChange?()
                throw error
            }
        }
        stateDidChange?()
    }

    static func cancel(_ id: UUID) { jobs[id]?.task?.cancel() }

    @discardableResult
    static func save(bundle: VMBundle, settings: VMSettings) async throws -> VMSettings {
        try begin(bundle: bundle, settings: settings)
        if let task = jobs[bundle.id]?.task { try await task.value }
        return try bundle.resolvedSettings()
    }

    private static func sameRequest(_ lhs: VMSettings, _ rhs: VMSettings) -> Bool {
        lhs.diskPath == rhs.diskPath && lhs.restoreImagePath == rhs.restoreImagePath
            && lhs.installationMediaPath == rhs.installationMediaPath
            && lhs.driverMediaPath == rhs.driverMediaPath
            && lhs.bootFromInstaller == rhs.bootFromInstaller
            && lhs.windowsCulture == rhs.windowsCulture
            && lhs.automaticWindowsDrivers == rhs.automaticWindowsDrivers
    }
}
