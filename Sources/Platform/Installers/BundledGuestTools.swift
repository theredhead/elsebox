import Foundation

/// The tested custom driver image belongs to the app, never the disposable installer cache.
enum BundledGuestTools {
    static let audioImageDigest = "e07ed0072a3322cf34fbb0d0f78f68749d1626d18bbb48abc351481a34ef136e"

    static var imageURL: URL? {
        Bundle.main.url(forResource: "GuestTools", withExtension: "iso", subdirectory: "WindowsBootstrap")
    }

    static func removeLegacyCacheCopy(cache: InstallerMediaCache, machines: [VMBundle]) throws {
        guard let imageURL, try InstallerMediaCache.sha256(of: imageURL) == audioImageDigest else { return }

        let old = cache.file(digest: audioImageDigest, extension: "iso")
        guard FileManager.default.fileExists(atPath: old.path) else { return }
        for machine in machines {
            let settings = try machine.resolvedSettings()
            if [settings.restoreImagePath, settings.installationMediaPath, settings.driverMediaPath].contains(
                old.path)
            {
                return
            }
        }
        guard try InstallerMediaCache.sha256(of: old) == audioImageDigest else { return }
        try FileManager.default.removeItem(at: old)
    }
}
