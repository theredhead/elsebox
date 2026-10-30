import Foundation
import Virtualization

enum VMDiskStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nl.theredhead.virtualmac", isDirectory: true)
    }

    static var defaultDisk: URL { directory.appendingPathComponent("Disk.img") }

    static func disk(for settings: VMSettings) -> URL {
        settings.diskPath.map { URL(fileURLWithPath: $0) } ?? defaultDisk
    }

    static func logicalCapacity(for settings: VMSettings) -> UInt64 {
        let size = (try? disk(for: settings).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return UInt64(max(0, size))
    }

    static func metadata(for disk: URL) -> URL {
        if disk.deletingLastPathComponent().pathExtension.lowercased() == "asvm" {
            return disk.deletingLastPathComponent()
        }
        if disk.standardizedFileURL.resolvingSymlinksInPath()
            == defaultDisk.standardizedFileURL.resolvingSymlinksInPath()
        {
            return directory  // Preserve the original VM's identity and installation marker.
        }
        return URL(fileURLWithPath: disk.path + ".virtualmac", isDirectory: true)
    }

    static func validate(_ disk: URL) throws {
        let values = try disk.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else {
            throw settingsError("Choose a nonempty RAW disk image created by VirtualMac.")
        }

        let metadata = metadata(for: disk)
        let fm = FileManager.default
        guard
            disk.standardizedFileURL == defaultDisk.standardizedFileURL
                || fm.fileExists(atPath: metadata.appendingPathComponent("ManagedDisk").path)
        else {
            throw settingsError(
                "This disk has no VirtualMac identity files. Choose a disk created by VirtualMac, keeping its .virtualmac folder alongside it. A macOS disk alone does not contain its virtual hardware identity."
            )
        }
    }

    /// Creates a new sparse RAW disk, never overwriting an existing path or identity folder.
    static func create(at disk: URL, capacityGB: Int) throws {
        guard (8...4096).contains(capacityGB) else {
            throw settingsError("New disk capacity must be between 8 and 4096 GB.")
        }

        let fm = FileManager.default
        let metadata = metadata(for: disk)
        let legacyDefault = metadata == directory || metadata.pathExtension.lowercased() == "asvm"
        if !legacyDefault && fm.fileExists(atPath: metadata.path) {
            throw settingsError("An identity folder already exists for that name. Choose another name.")
        }
        try HostFileOperations.createSparseDisk(at: disk, capacityBytes: UInt64(capacityGB) * 1_000_000_000)
        var createdMetadata = false
        do {
            if !legacyDefault {
                try HostFileOperations.createDirectoryExclusively(at: metadata)
                createdMetadata = true
                try Data().write(to: metadata.appendingPathComponent("ManagedDisk"), options: .atomic)
            }
        } catch {
            try? fm.removeItem(at: disk)
            if createdMetadata { try? fm.removeItem(at: metadata) }
            throw error
        }
    }

    static func validateShares(_ shares: [SharedFolder]) throws {
        var names = Set<String>()
        for share in shares {
            guard !share.name.isEmpty, share.name != ".", share.name != "..",
                !share.name.contains("/"), !share.name.contains(":"), !share.name.contains("\0"),
                share.name.utf8.count <= 255
            else {
                throw settingsError(
                    "Each shared folder needs a name of up to 255 bytes without slashes or colons.")
            }
            try VZMultipleDirectoryShare.validateName(share.name)
            guard names.insert(share.name.lowercased()).inserted else {
                throw settingsError("Shared folder names must be unique: \(share.name)")
            }

            let values = try URL(fileURLWithPath: share.path).resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true else {
                throw settingsError("Shared folder is unavailable: \(share.path)")
            }
        }
    }
}
