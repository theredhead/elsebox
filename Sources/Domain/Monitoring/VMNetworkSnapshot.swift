import Foundation

struct VMNetworkSnapshot: Codable {
    let macAddresses: [String]
    let addresses: [String]
    let observedAt: Date
}
