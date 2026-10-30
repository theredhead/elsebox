import Darwin
import Foundation

struct VMNetworkSnapshot: Codable {
    let macAddresses: [String]
    let addresses: [String]
    let observedAt: Date

    static func read(from bundleURL: URL) -> VMNetworkSnapshot? {
        guard let data = try? Data(contentsOf: bundleURL.appendingPathComponent("NetworkAddresses.json"))
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// Passive matching of host DHCP/neighbor records to a VM's actual configured MAC addresses.
enum VMNetworkAddressParser {
    static func mac(_ value: String) -> String? {
        let parts = value.split(separator: ",").last?.split(separator: ":") ?? []
        guard parts.count == 6 else { return nil }
        var normalized: [String] = []
        for part in parts {
            guard (1...2).contains(part.count), let byte = UInt8(part, radix: 16) else { return nil }
            normalized.append(String(format: "%02x", byte))
        }
        return normalized.joined(separator: ":")
    }

    static func parse(dhcp: String, arp: String, ndp: String, now: Date = Date()) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for record in dhcp.split(separator: "}") {
            var fields: [String: String] = [:]
            for line in record.split(whereSeparator: \.isNewline) {
                let pair = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if pair.count == 2 { fields[pair[0]] = pair[1] }
            }
            guard let hardware = fields["hw_address"].flatMap(mac), let ip = fields["ip_address"], validIP(ip)
            else { continue }
            if let lease = fields["lease"],
                let expiration = UInt64(lease.replacingOccurrences(of: "0x", with: ""), radix: 16),
                expiration != 0xFFFF_FFFF, Double(expiration) <= now.timeIntervalSince1970
            {
                continue
            }
            result[hardware, default: []].insert(ip)
        }
        for line in arp.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let at = parts.firstIndex(of: "at"), at > 0, parts.indices.contains(at + 1),
                let hardware = mac(parts[at + 1])
            else { continue }
            let ip = parts[at - 1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            if validIP(ip) { result[hardware, default: []].insert(ip) }
        }
        for line in ndp.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2, let hardware = mac(parts[1]), validIP(parts[0]) else { continue }
            result[hardware, default: []].insert(parts[0])
        }
        return result
    }

    private static func validIP(_ value: String) -> Bool {
        guard let first = value.split(separator: "%", maxSplits: 1).first else { return false }
        let literal = String(first)
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_pton(AF_INET, literal, &ipv4) == 1 { return literal != "0.0.0.0" }
        return inet_pton(AF_INET6, literal, &ipv6) == 1 && literal != "::"
    }
}

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
