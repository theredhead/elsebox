import Foundation

/// Owns the known-bundle registry and migration bookkeeping so filesystem discovery is separate from windows and running sessions.
final class VMLibrary {
    struct Registry: Codable {
        var version = 1
        var paths: [String] = []
        var legacyMigrationCompleted = false
    }

    let root: URL

    var mediaCache: InstallerMediaCache {
        return InstallerMediaCache(root: root.appendingPathComponent("Install Media"))
    }

    private var registry = Registry()
    private(set) var machines: [VMBundle] = []

    var registryURL: URL { root.appendingPathComponent("Registry.json") }

    var defaultLocation: URL { root.appendingPathComponent("Virtual Machines", isDirectory: true) }

    init(root: URL = VMDiskStore.directory) { self.root = root }

    func load() throws {
        try FileManager.default.createDirectory(at: defaultLocation, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: registryURL.path) {
            registry = try JSONDecoder().decode(Registry.self, from: Data(contentsOf: registryURL))
            guard registry.version == 1 else { throw settingsError("Unsupported VM registry version.") }
        }
        try refresh()
    }

    /// Invalid, missing, moved or renamed paths are dropped. No bundle files are deleted.
    func refresh() throws {
        var ids = Set<UUID>()
        machines = registry.paths.compactMap { path in
            guard let machine = try? VMBundle.open(URL(fileURLWithPath: path), mediaCache: mediaCache),
                ids.insert(machine.id).inserted
            else { return nil }
            return machine
        }
        registry.paths = machines.map { $0.url.path }
        try persist()
    }

    func register(_ url: URL) throws -> VMBundle {
        try refresh()
        let machine = try VMBundle.open(url, mediaCache: mediaCache)
        if let existing = machines.first(where: { $0.id == machine.id }) {
            guard existing.url == machine.url else {
                throw settingsError(
                    "A bundle with this VM identity is already registered at \(existing.url.path). Move it rather than copying it, or create a new VM for a separate identity."
                )
            }
            return existing
        }
        machines.append(machine)
        registry.paths = machines.map { $0.url.path }
        try persist()
        return machine
    }

    func remove(_ id: UUID) throws {
        machines.removeAll { $0.id == id }
        registry.paths = machines.map { $0.url.path }
        try persist()
    }

    private func persist() throws {
        try JSONEncoder().encode(registry).write(to: registryURL, options: .atomic)
    }

    /// Copy the previous single-VM setup once; the original files remain as a backup.
    func migrateLegacyIfNeeded(from legacy: URL) throws {
        guard !registry.legacyMigrationCompleted else { return }

        let fm = FileManager.default
        let oldSettingsURL = legacy.appendingPathComponent("Resources.json")
        let defaultDisk = legacy.appendingPathComponent("Disk.img")
        guard fm.fileExists(atPath: oldSettingsURL.path) || fm.fileExists(atPath: defaultDisk.path) else {
            registry.legacyMigrationCompleted = true
            try persist()
            return
        }

        var settings =
            fm.fileExists(atPath: oldSettingsURL.path)
            ? try JSONDecoder().decode(VMSettings.self, from: Data(contentsOf: oldSettingsURL))
            : VMSettings(cpu: 4, memory: 4 * 1_073_741_824)
        if settings.showsStatusBar == nil {
            settings.showsStatusBar = UserDefaults.standard.object(forKey: "showsStatusBar") as? Bool
        }

        let disk = settings.diskPath.map { URL(fileURLWithPath: $0) } ?? defaultDisk
        guard fm.fileExists(atPath: disk.path) else {
            throw settingsError(
                "The previous startup disk is missing. Locate it before migrating the previous VM.")
        }

        let destination = defaultLocation.appendingPathComponent("ElseBox.asvm")
        if fm.fileExists(atPath: destination.path) {
            // Recover a migration completed before a registry write was interrupted.
            _ = try register(destination)
            registry.legacyMigrationCompleted = true
            try persist()
            return
        }

        let staging = defaultLocation.appendingPathComponent(".migration-\(UUID().uuidString).asvm")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let sourceMetadata =
                disk.standardizedFileURL == defaultDisk.standardizedFileURL
                ? legacy : VMDiskStore.metadata(for: disk)
            try Self.withDiskReadLock(disk) {
                try VMBundle.copyAsset(from: disk, to: staging.appendingPathComponent("Disk.img"))
                try VMBundle.copyIdentity(from: sourceMetadata, to: staging)
            }
            settings.diskPath = "Disk.img"
            if let path = settings.restoreImagePath {
                try VMBundle.copyAsset(
                    from: URL(fileURLWithPath: path), to: staging.appendingPathComponent("RestoreImage.ipsw"))
                settings.restoreImagePath = "RestoreImage.ipsw"
            } else if fm.fileExists(atPath: legacy.appendingPathComponent("RestoreImage.ipsw").path) {
                try VMBundle.copyAsset(
                    from: legacy.appendingPathComponent("RestoreImage.ipsw"),
                    to: staging.appendingPathComponent("RestoreImage.ipsw"))
            }
            if settings.sharedFolders == nil {
                settings.sharedFolders = [
                    SharedFolder(
                        name: "Shared", path: legacy.appendingPathComponent("Shared").path, readOnly: false)
                ]
            }

            let manifest = VMManifest(id: UUID(), name: "ElseBox")
            try JSONEncoder().encode(manifest).write(
                to: staging.appendingPathComponent("VM.json"), options: .atomic)
            try JSONEncoder().encode(settings).write(
                to: staging.appendingPathComponent("Resources.json"), options: .atomic)
            try fm.createDirectory(
                at: staging.appendingPathComponent("Shared"), withIntermediateDirectories: true)
            try fm.moveItem(at: staging, to: destination)
            _ = try register(destination)
            registry.legacyMigrationCompleted = true
            try persist()
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func withDiskReadLock(_ url: URL, operation: () throws -> Void) throws {
        let lease = try ExclusiveFileLease(
            file: url, createIfMissing: false,
            inUseMessage: "The previous VM disk is in use. Shut down that VM before migration or import.")
        defer { withExtendedLifetime(lease) {} }
        try operation()
    }
}
