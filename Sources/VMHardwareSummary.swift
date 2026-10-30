import Foundation

/// Displays configured resources and logical disk capacity, rather than allocated host storage.
enum VMHardwareSummary {
    static func text(settings: Resources) -> String {
        let disk = VMDiskStore.disk(for: settings)
        let bytes = (try? disk.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return
            "\(settings.cpu) cores · \(settings.memory / 1_073_741_824) GiB RAM · \(bytes / 1_000_000_000) GB disk"
    }
}
