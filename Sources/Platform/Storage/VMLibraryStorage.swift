import Foundation

struct VMLibraryStorageUsage {
    let vmBytes: Int64
    let mediaBytes: Int64
}

/// Counts allocated files, including sparse disks, without following links outside library roots.
enum VMLibraryStorage {
    static func measure(vmURLs: [URL], mediaURL: URL) throws -> VMLibraryStorageUsage {
        let media = mediaURL.standardizedFileURL.resolvingSymlinksInPath()
        let roots = Set(vmURLs.map { $0.standardizedFileURL.resolvingSymlinksInPath() }).sorted {
            $0.path.count < $1.path.count
        }
        var counted: [URL] = []
        var vmBytes: Int64 = 0
        for root in roots where !counted.contains(where: { root.path.hasPrefix($0.path + "/") }) {
            guard root != media, !root.path.hasPrefix(media.path + "/") else { continue }
            vmBytes += try allocatedBytes(at: root)
            counted.append(root)
        }
        let mediaBytes =
            counted.contains(where: { media.path.hasPrefix($0.path + "/") })
            ? 0 : try allocatedBytes(at: media)
        return VMLibraryStorageUsage(vmBytes: vmBytes, mediaBytes: mediaBytes)
    }

    private static func allocatedBytes(at root: URL) throws -> Int64 {
        guard FileManager.default.fileExists(atPath: root.path) else { return 0 }
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        var enumerationError: Error?
        guard
            let files = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                })
        else { throw CocoaError(.fileReadUnknown) }
        var bytes: Int64 = 0
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                files.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                guard let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize else {
                    throw CocoaError(.fileReadUnknown)
                }
                bytes += Int64(size)
            }
        }
        if let enumerationError { throw enumerationError }
        return bytes
    }
}
