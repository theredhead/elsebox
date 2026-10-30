import Foundation

struct CachedInstallerFile {
    let url: URL
    let relativePath: String
    let allocatedBytes: Int64
}

/// Only completed media inside the cache is offered for individual cleanup.
enum InstallerMediaInventory {
    static func files(in root: URL, excludingDigests: Set<String> = []) throws -> [CachedInstallerFile] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys))
        else { throw CocoaError(.fileReadUnknown) }
        var result: [CachedInstallerFile] = []
        for case let url as URL in files {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else {
                files.skipDescendants()
                continue
            }
            guard values.isRegularFile == true, isMedia(url, inside: root),
                !excludingDigests.contains(url.deletingLastPathComponent().lastPathComponent)
            else { continue }
            result.append(
                CachedInstallerFile(
                    url: url,
                    relativePath: String(url.path.dropFirst(root.path.count + 1)),
                    allocatedBytes: Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)))
        }
        return result.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    static func canRecreate(_ entry: CachedInstallerFile, root: URL, downloadable: Set<URL>) -> Bool {
        let path = entry.url.standardizedFileURL.resolvingSymlinksInPath().path
        if downloadable.contains(where: { $0.standardizedFileURL.resolvingSymlinksInPath().path == path }) {
            return true
        }
        let parts = entry.relativePath.split(separator: "/")
        guard parts.count == 3, parts[0] == "Windows Bootstrap", parts[2] == "Installer-v1.img",
            parts[1].count == 64, parts[1].allSatisfy({ "0123456789abcdef".contains($0) })
        else { return false }
        let source = root.appendingPathComponent(String(parts[1])).appendingPathComponent("Installer.iso")
        return isMedia(source, inside: root) && FileManager.default.isReadableFile(atPath: source.path)
    }

    static func volumeName(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 16 * 2048)) != nil,
            let data = try? handle.read(upToCount: 2048), data.count == 2048,
            String(decoding: data[1..<6], as: UTF8.self) == "CD001"
        else { return nil }
        return String(decoding: data[40..<72], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }

    static func isMedia(_ url: URL, inside root: URL) -> Bool {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        return target.path.hasPrefix(root.path + "/")
            && ["iso", "ipsw", "img"].contains(target.pathExtension.lowercased())
            && !target.lastPathComponent.hasPrefix("Preparing-")
    }
}
