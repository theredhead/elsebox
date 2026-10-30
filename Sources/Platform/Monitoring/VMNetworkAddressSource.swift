import Foundation

/// Shares one passive host-table read between all running VMs every five seconds.
actor VMNetworkAddressSource {
    static let shared = VMNetworkAddressSource()
    private var updatedAt = Date.distantPast
    private var cached: [String: Set<String>] = [:]
    private var reading: Task<[String: Set<String>], Never>?

    func addresses(for macAddresses: [String]) async -> [String] {
        if Date().timeIntervalSince(updatedAt) >= 5 {
            let task: Task<[String: Set<String>], Never>
            if let reading {
                task = reading
            } else {
                task = Task.detached(priority: .utility) {
                    let dhcp = (try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8)) ?? ""
                    return VMNetworkAddressParser.parse(
                        dhcp: dhcp,
                        arp: Self.output("/usr/sbin/arp"), ndp: Self.output("/usr/sbin/ndp"))
                }
                reading = task
            }
            cached = await task.value
            updatedAt = Date()
            reading = nil
        }
        return Set(macAddresses.compactMap(VMNetworkAddressParser.mac).flatMap { cached[$0] ?? [] }).sorted()
    }

    private static func output(_ command: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
        } catch { return "" }
    }
}
