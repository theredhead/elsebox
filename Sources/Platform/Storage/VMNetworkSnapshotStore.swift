import Foundation

/// Persists only the last observed network state; it never probes or changes a guest.
enum VMNetworkSnapshotStore {
    static func read(from bundleURL: URL) -> VMNetworkSnapshot? {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("NetworkAddresses.json"))
        else { return nil }
        return try? JSONDecoder().decode(VMNetworkSnapshot.self, from: data)
    }

    static func write(_ snapshot: VMNetworkSnapshot, to bundleURL: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: bundleURL.appendingPathComponent("NetworkAddresses.json"), options: .atomic)
    }
}
