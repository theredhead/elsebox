import Foundation

struct VMManifest: Codable {
    var version = 1
    var id: UUID
    var name: String
    var distribution: GuestDistribution? = nil
    var role: GuestRole? = nil
}
