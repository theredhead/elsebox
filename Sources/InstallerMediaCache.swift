import CryptoKit
import Foundation

/// Shared content-addressed installers. VM files retain media:// references, not copies.
struct InstallerMediaCache {
    let root: URL
    static var shared: InstallerMediaCache {
        return InstallerMediaCache(root: VMDiskStore.directory.appendingPathComponent("Install Media"))
    }

    func file(digest: String, extension suffix: String) -> URL {
        return root.appendingPathComponent(digest).appendingPathComponent("Installer.\(suffix)")
    }

    func reference(for file: URL) -> String? {
        let prefix = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(prefix) else { return nil }
        let parts = String(path.dropFirst(prefix.count)).split(separator: "/")
        guard parts.count == 2, Self.validDigest(String(parts[0])),
            parts[1] == "Installer.iso" || parts[1] == "Installer.ipsw"
        else { return nil }
        var components = URLComponents()
        components.scheme = "media"
        components.host = String(parts[0])
        components.path = "/" + parts[1]
        return components.string
    }

    func resolve(_ reference: String) throws -> URL {
        guard let components = URLComponents(string: reference), components.scheme == "media",
            let digest = components.host, Self.validDigest(digest), components.query == nil,
            components.fragment == nil
        else {
            throw settingsError("Invalid shared installer reference.")
        }
        let filename = String(components.path.dropFirst())
        guard filename == "Installer.iso" || filename == "Installer.ipsw" else {
            throw settingsError("Invalid installer filename.")
        }
        let file = root.appendingPathComponent(digest).appendingPathComponent(filename).standardizedFileURL
            .resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
            throw settingsError("Installer reference escapes the shared cache.")
        }
        return file
    }

    func importFile(_ source: URL) throws -> URL {
        if reference(for: source) != nil { return source }
        let digest = try Self.sha256(of: source)
        let suffix = source.pathExtension.lowercased() == "ipsw" ? "ipsw" : "iso"
        let target = file(digest: digest, extension: suffix)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            do { try HostFileOperations.copyPreservingAllocation(from: source, to: target) } catch {
                if !FileManager.default.fileExists(atPath: target.path) { throw error }
            }
        }
        return target
    }

    func commit(_ temporary: URL, digest: String, extension suffix: String) throws -> URL {
        let target = file(digest: digest, extension: suffix)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: target.path) {
            do { try FileManager.default.moveItem(at: temporary, to: target) } catch {
                if !FileManager.default.fileExists(atPath: target.path) { throw error }
            }
        }
        return target
    }

    func cached(for key: String) -> URL? {
        guard let data = try? Data(contentsOf: indexFile(key)),
            let reference = String(data: data, encoding: .utf8),
            let file = try? resolve(reference), FileManager.default.isReadableFile(atPath: file.path)
        else { return nil }
        return file
    }

    func remember(_ file: URL, for key: String) throws {
        guard let reference = reference(for: file) else {
            throw settingsError("Installer is outside the shared cache.")
        }
        let index = indexFile(key)
        try FileManager.default.createDirectory(
            at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(reference.utf8).write(to: index, options: .atomic)
    }

    func acquire(_ key: String) async throws -> ExclusiveFileLease {
        let folder = root.appendingPathComponent("Locks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let lockFile = folder.appendingPathComponent(Self.keyDigest(key))
        while true {
            try Task.checkCancellation()
            do {
                return try ExclusiveFileLease(
                    file: lockFile, inUseMessage: "Installer is being prepared by another VM.")
            } catch let error as NSError where error.domain == "nl.theredhead.virtualmac" {
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    static func key(for preset: VMStarterPreset) -> String {
        switch preset.distribution {
        case .macOS: return "macOS"
        case .debian: return "debian-arm64-netinst"
        case .ubuntu: return preset.role == .desktop ? "ubuntu-arm64-desktop" : "ubuntu-arm64-server"
        case .fedora: return "fedora-aarch64-\(preset.role.rawValue)"
        case .arch, .customLinux, .windows: return preset.distribution.rawValue
        }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func indexFile(_ key: String) -> URL {
        return root.appendingPathComponent("Index/\(Self.keyDigest(key)).txt")
    }
    private static func keyDigest(_ key: String) -> String {
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func validDigest(_ text: String) -> Bool {
        return text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
