import Foundation

struct RecentDiskImage: Codable, Equatable {
    let path: String
    let readOnly: Bool
}

/// A bounded, shared list of successfully mounted host images; missing paths are discarded.
enum RecentDiskImages {
    private static let key = "RecentDiskImages"

    static func load(defaults: UserDefaults = .standard) -> [RecentDiskImage] {
        guard let data = defaults.data(forKey: key),
            let entries = try? JSONDecoder().decode([RecentDiskImage].self, from: data)
        else { return [] }
        return entries.filter { FileManager.default.isReadableFile(atPath: $0.path) }
    }

    static func remember(_ url: URL, readOnly: Bool, defaults: UserDefaults = .standard) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        var entries = load(defaults: defaults).filter { $0.path != path }
        entries.insert(RecentDiskImage(path: path, readOnly: readOnly), at: 0)
        if let data = try? JSONEncoder().encode(Array(entries.prefix(10))) { defaults.set(data, forKey: key) }
    }
}
