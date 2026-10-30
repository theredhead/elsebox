import Foundation

/// Displays configured resources and logical disk capacity, rather than allocated host storage.
enum VMHardwareSummary {
    static func text(settings: VMSettings, diskCapacity: UInt64) -> String {
        return
            "\(settings.cpu) cores · \(settings.memory / 1_073_741_824) GiB RAM · \(diskCapacity / 1_000_000_000) GB disk"
    }
}
