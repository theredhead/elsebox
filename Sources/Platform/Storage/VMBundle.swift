import Foundation

struct VMBundle: Identifiable {
    let url: URL
    let manifest: VMManifest
    var mediaCache: InstallerMediaCache = .shared
    var id: UUID { manifest.id }
    var name: String { manifest.name }
    var distribution: GuestDistribution { return manifest.distribution ?? .macOS }
    var preset: VMStarterPreset {
        return VMStarterPreset(distribution: distribution, role: manifest.role ?? .desktop)
    }
    var settingsURL: URL { url.appendingPathComponent("Resources.json") }

    static func open(_ url: URL, mediaCache: InstallerMediaCache = .shared) throws -> VMBundle {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "asvm" else {
            throw settingsError("Choose an .asvm virtual machine bundle.")
        }
        let manifest = try JSONDecoder().decode(
            VMManifest.self, from: Data(contentsOf: url.appendingPathComponent("VM.json")))
        guard manifest.version == 1, !manifest.name.isEmpty else {
            throw settingsError("Unsupported or invalid VM bundle.")
        }
        let bundle = VMBundle(url: url, manifest: manifest, mediaCache: mediaCache)
        let settings = try bundle.storedSettings()
        let disk = try bundle.assetURL(settings.diskPath ?? "Disk.img")
        guard try disk.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw settingsError("The VM startup disk is unavailable.")
        }
        return bundle
    }

    func storedSettings() throws -> VMSettings {
        let settings = try JSONDecoder().decode(VMSettings.self, from: Data(contentsOf: settingsURL))
        _ = try assetURL(settings.diskPath ?? "Disk.img")
        if let path = settings.restoreImagePath { _ = try installerURL(path) }
        if let path = settings.installationMediaPath { _ = try installerURL(path) }
        if let path = settings.driverMediaPath { _ = try installerURL(path) }
        return settings
    }

    /// Internal assets must stay in the bundle, including after it is moved.
    func assetURL(_ relativePath: String) throws -> URL {
        guard !relativePath.hasPrefix("/"), !relativePath.isEmpty else {
            throw settingsError("VM disk and restore-image paths must be relative to the .asvm bundle.")
        }
        let candidate = url.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(url.path + "/") else {
            throw settingsError("An asset path escapes its VM bundle.")
        }
        return candidate
    }

    private func installerURL(_ path: String) throws -> URL {
        if path.hasPrefix("media://") { return try mediaCache.resolve(path) }
        return try assetURL(path)  // Read bundles created before the shared cache was introduced.
    }

    func resolvedSettings() throws -> VMSettings {
        var result = try storedSettings()
        result.diskPath = try assetURL(result.diskPath ?? "Disk.img").path
        if let path = result.restoreImagePath { result.restoreImagePath = try installerURL(path).path }
        if let path = result.installationMediaPath {
            result.installationMediaPath = try installerURL(path).path
        }
        if let path = result.driverMediaPath { result.driverMediaPath = try installerURL(path).path }
        result.sharedFolders = try result.sharedFolders?.map { share in
            var share = share
            if !share.path.hasPrefix("/") { share.path = try assetURL(share.path).path }
            return share
        }
        return result
    }

    func save(_ settings: VMSettings) throws {
        var stored = settings
        let disk = VMDiskStore.disk(for: settings)
        let internalDisk: URL
        if contains(disk) {
            internalDisk = disk
        } else {
            // Import the image AND identity without modifying the original VM.
            let target = url.appendingPathComponent("Disks/\(UUID().uuidString)/Disk.img")
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try VMDiskStore.validate(disk)
            let sourceMetadata = VMDiskStore.metadata(for: disk)
            let macIdentity = FileManager.default.fileExists(
                atPath: sourceMetadata.appendingPathComponent("HardwareModel").path)
            let linuxIdentity = FileManager.default.fileExists(
                atPath: sourceMetadata.appendingPathComponent("EFIVariableStore").path)
            guard !(distribution.usesEFI && macIdentity), !(!distribution.usesEFI && linuxIdentity) else {
                throw settingsError("The startup disk belongs to a different guest family.")
            }
            let sourceBundle = Self.enclosingBundle(of: disk)
            let sourceLease = try sourceBundle.map { try VMLease(directory: $0) }
            defer { withExtendedLifetime(sourceLease) {} }
            try VMLibrary.withDiskReadLock(disk) {
                try Self.copyAsset(from: disk, to: target)
                try Self.copyIdentity(
                    from: VMDiskStore.metadata(for: disk), to: VMDiskStore.metadata(for: target))
            }
            internalDisk = target
        }
        stored.diskPath = relativePath(internalDisk)
        if let path = settings.restoreImagePath {
            let media = try mediaCache.importFile(URL(fileURLWithPath: path))
            stored.restoreImagePath = mediaCache.reference(for: media)
        }
        if let path = settings.installationMediaPath {
            let media = try mediaCache.importFile(URL(fileURLWithPath: path))
            stored.installationMediaPath = mediaCache.reference(for: media)
        }
        if let path = settings.driverMediaPath {
            let media = try mediaCache.importFile(URL(fileURLWithPath: path))
            stored.driverMediaPath = mediaCache.reference(for: media)
        }
        stored.sharedFolders = settings.sharedFolders?.map { share in
            var result = share
            let folder = URL(fileURLWithPath: share.path)
            if contains(folder) { result.path = relativePath(folder) }
            return result
        }
        try JSONEncoder().encode(stored).write(to: settingsURL, options: .atomic)
    }

    func contains(_ asset: URL) -> Bool {
        asset.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(url.path + "/")
    }

    private func relativePath(_ asset: URL) -> String {
        String(asset.standardizedFileURL.resolvingSymlinksInPath().path.dropFirst(url.path.count + 1))
    }

    static func enclosingBundle(of asset: URL) -> URL? {
        var parent = asset.deletingLastPathComponent()
        while parent.path != "/" {
            if parent.pathExtension.lowercased() == "asvm" { return parent }
            parent.deleteLastPathComponent()
        }
        return nil
    }

    static func create(
        at url: URL, name: String, capacityGB: Int, preset: VMStarterPreset = .macOS,
        mediaCache: InstallerMediaCache = .shared
    ) throws
        -> VMBundle
    {
        let fm = FileManager.default
        guard url.pathExtension.lowercased() == "asvm",
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw settingsError("Choose a name and a location ending in .asvm.")
        }
        try HostFileOperations.createDirectoryExclusively(at: url)
        do {
            let manifest = VMManifest(
                id: UUID(), name: name, distribution: preset.distribution, role: preset.role)
            let bundle = VMBundle(
                url: url.standardizedFileURL.resolvingSymlinksInPath(), manifest: manifest,
                mediaCache: mediaCache)
            try JSONEncoder().encode(manifest).write(
                to: url.appendingPathComponent("VM.json"), options: .atomic)
            try Data().write(to: url.appendingPathComponent("ManagedDisk"), options: .atomic)
            try VMDiskStore.create(at: url.appendingPathComponent("Disk.img"), capacityGB: capacityGB)
            try fm.createDirectory(
                at: url.appendingPathComponent("Shared"), withIntermediateDirectories: true)
            let settings = VMSettings(
                cpu: min(preset.cpu, ProcessInfo.processInfo.processorCount),
                memory: UInt64(preset.memoryGiB) * 1_073_741_824,
                pixelsPerInch: 72, diskPath: "Disk.img",
                automaticWindowsDrivers: preset.distribution == .windows, sharedFolders: [])
            try JSONEncoder().encode(settings).write(to: bundle.settingsURL, options: .atomic)
            return bundle
        } catch {
            try? fm.removeItem(at: url)  // Only the newly created, incomplete bundle.
            throw error
        }
    }

    static func copyAsset(from source: URL, to target: URL) throws {
        // APFS copy-on-write preserves sparse allocation and avoids copying entire VM disks.
        try HostFileOperations.copyPreservingAllocation(from: source, to: target)
    }

    static func copyIdentity(from source: URL, to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for name in [
            "HardwareModel", "MachineIdentifier", "AuxiliaryStorage", "MinimumResources.json",
            "EFIVariableStore", "Installed",
        ] {
            let original = source.appendingPathComponent(name)
            if fm.fileExists(atPath: original.path) {
                try copyAsset(from: original, to: target.appendingPathComponent(name))
            }
        }
        try Data().write(to: target.appendingPathComponent("ManagedDisk"), options: .atomic)
    }
}
