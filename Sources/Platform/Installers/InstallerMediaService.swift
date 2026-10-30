import Foundation
import Virtualization

/// Prepares shared media before settings are committed. Download failures leave
/// the old VM configuration untouched and never publish a partial installer.
actor InstallerMediaService {
    // Official Fedora-hosted VirtIO release, pinned to the downloaded SHA-256 digest.
    static let windowsDriverImage = InstallerImage(
        url: URL(
            string:
                "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.302-1/virtio-win-0.1.302.iso"
        )!,
        sha256: "303f7ae40dad495d6ae474fdc571df58958a4dbc5c37a522d80f9a203867949d")
    private let windowsInstaller: (@Sendable () async throws -> InstallerImage)?
    private let transport: any InstallerTransport

    init(
        transport: any InstallerTransport = HTTPInstallerTransport(),
        windowsInstaller: (@Sendable () async throws -> InstallerImage)? = nil
    ) {
        self.windowsInstaller = windowsInstaller
        self.transport = transport
    }

    static func needsDownload(bundle: VMBundle, settings: VMSettings) -> Bool {
        if bundle.distribution == .windows {
            guard settings.bootFromInstaller != false else { return false }
            return settings.installationMediaPath == nil
        }
        if bundle.distribution.usesEFI {
            return settings.bootFromInstaller != false && settings.installationMediaPath == nil
        }
        return settings.restoreImagePath == nil
            && (!FileManager.default.fileExists(
                atPath: VMDiskStore.metadata(for: VMDiskStore.disk(for: settings)).appendingPathComponent(
                    "Installed"
                ).path)
                || FileManager.default.fileExists(
                    atPath: bundle.url.appendingPathComponent("RestoreImage.ipsw").path))
    }

    func prepare(
        bundle: VMBundle, settings: VMSettings, progress: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> VMSettings {
        if bundle.distribution == .windows {
            let ready = try await prepareWindowsInstaller(
                bundle: bundle, settings: settings, progress: progress)
            return try await prepareWindowsDrivers(bundle: bundle, settings: ready, progress: progress)
        }
        guard bundle.distribution.hasAutomaticInstaller else { return settings }
        guard Self.needsDownload(bundle: bundle, settings: settings) else { return settings }
        try Task.checkCancellation()
        let cache = bundle.mediaCache
        let key = InstallerMediaCache.key(for: bundle.preset)
        progress("Preparing \(bundle.distribution.title) installer…", nil)
        let lease = try await cache.acquire(key)
        defer { withExtendedLifetime(lease) {} }
        if let cached = cache.cached(for: key) {
            if bundle.distribution.usesEFI { return selecting(cached, in: settings, linux: true) }
            if let restore = try? await VZMacOSRestoreImage.image(from: cached),
                restore.mostFeaturefulSupportedConfiguration != nil
            {
                return selecting(cached, in: settings, linux: false)
            }
        }
        if !bundle.distribution.usesEFI {
            let oldCache = bundle.url.appendingPathComponent("RestoreImage.ipsw")
            if FileManager.default.isReadableFile(atPath: oldCache.path) {
                let target = try cache.importFile(oldCache)
                try cache.remember(target, for: key)
                return selecting(target, in: settings, linux: false)
            }
            progress("Finding macOS restore image…", nil)
            let restore = try await VZMacOSRestoreImage.latestSupported
            let downloaded = try await transport.download(from: restore.url) {
                progress("Downloading macOS…", $0)
            }
            // Virtualization validates the restore-image file type as well as its contents.
            let temporary = downloaded.appendingPathExtension("ipsw")
            defer {
                try? FileManager.default.removeItem(at: downloaded)
                try? FileManager.default.removeItem(at: temporary)
            }
            try FileManager.default.moveItem(at: downloaded, to: temporary)
            try Task.checkCancellation()
            progress("Checking macOS restore image…", nil)
            _ = try await VZMacOSRestoreImage.image(from: temporary)
            let digest = try InstallerMediaCache.sha256(of: temporary)
            try Task.checkCancellation()
            let target = try cache.commit(temporary, digest: digest, extension: "ipsw")
            try cache.remember(target, for: key)
            return selecting(target, in: settings, linux: false)
        }
        progress("Finding \(bundle.distribution.title) installer…", nil)
        let transport = self.transport
        let image = try await InstallerCatalog(fetch: { try await transport.data(from: $0) }).resolve(
            bundle.preset)
        let existing = cache.file(digest: image.sha256, extension: "iso")
        if FileManager.default.isReadableFile(atPath: existing.path) {
            try cache.remember(existing, for: key)
            return selecting(existing, in: settings, linux: true)
        }
        // Different presets may resolve to the same ISO. Serialize the content itself too.
        let imageLease = try await cache.acquire("image-\(image.sha256)")
        defer { withExtendedLifetime(imageLease) {} }
        if FileManager.default.isReadableFile(atPath: existing.path) {
            try cache.remember(existing, for: key)
            return selecting(existing, in: settings, linux: true)
        }

        let temporary = try await transport.download(from: image.url) {
            progress("Downloading \(bundle.distribution.title)…", $0)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        progress("Verifying installer…", nil)
        let digest = try InstallerMediaCache.sha256(of: temporary)
        guard digest == image.sha256 else {
            throw settingsError("The installer checksum does not match the publisher’s checksum. Try again.")
        }
        try Task.checkCancellation()
        let target = try cache.commit(temporary, digest: digest, extension: "iso")
        try cache.remember(target, for: key)
        return selecting(target, in: settings, linux: true)
    }

    private func prepareWindowsInstaller(
        bundle: VMBundle, settings: VMSettings, progress: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> VMSettings {
        guard settings.bootFromInstaller != false, settings.installationMediaPath == nil else {
            return settings
        }

        let cache = bundle.mediaCache
        let culture = WindowsCulture(rawValue: settings.windowsCulture ?? "en-US") ?? .englishUS
        let key = culture.cacheKey
        let lease = try await cache.acquire(key)
        defer { withExtendedLifetime(lease) {} }
        if let cached = cache.cached(for: key) { return selecting(cached, in: settings, linux: true) }
        progress("Requesting Windows ARM64 installer from Microsoft…", nil)
        let image: InstallerImage
        if let windowsInstaller {
            image = try await windowsInstaller()
        } else {
            image = try await WindowsInstallerResolver.resolve(culture: culture)
        }
        try Task.checkCancellation()
        let existing = cache.file(digest: image.sha256, extension: "iso")
        if FileManager.default.isReadableFile(atPath: existing.path) {
            try cache.remember(existing, for: key)
            return selecting(existing, in: settings, linux: true)
        }

        let temporary = try await transport.download(from: image.url) {
            progress("Downloading Windows 11 ARM64…", $0)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        progress("Verifying Windows installer…", nil)
        guard try InstallerMediaCache.sha256(of: temporary) == image.sha256 else {
            throw settingsError(
                "The Windows installer checksum does not match Microsoft’s checksum. Try again.")
        }
        try Task.checkCancellation()
        let target = try cache.commit(temporary, digest: image.sha256, extension: "iso")
        try cache.remember(target, for: key)
        return selecting(target, in: settings, linux: true)
    }

    private func prepareWindowsDrivers(
        bundle: VMBundle, settings: VMSettings, progress: @escaping @Sendable (String, Double?) -> Void
    ) async throws -> VMSettings {
        guard settings.automaticWindowsDrivers == true else {
            return settings
        }
        progress("Using bundled Windows VirtIO drivers…", nil)
        var result = settings
        result.driverMediaPath = nil
        return result
    }

    private func selecting(_ media: URL, in settings: VMSettings, linux: Bool) -> VMSettings {
        var result = settings
        if linux {
            result.installationMediaPath = media.path
            result.bootFromInstaller = true
        } else {
            result.restoreImagePath = media.path
        }
        return result
    }
}
