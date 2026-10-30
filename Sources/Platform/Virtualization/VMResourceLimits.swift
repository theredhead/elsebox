import Foundation
import Virtualization

/// Combines persisted guest requirements with current framework and host limits.
@MainActor
struct VMResourceLimits {
    let cpu: ClosedRange<Int>
    let memoryGiB: ClosedRange<Int>
    private static let gib: UInt64 = 1024 * 1024 * 1024

    static func load(metadata: URL, distribution: GuestDistribution) throws -> VMResourceLimits {
        var minimum = VMSettings(
            cpu: distribution.isLinux ? 1 : 2, memory: distribution.isLinux ? gib : 4 * gib)
        if FileManager.default.fileExists(
            atPath: metadata.appendingPathComponent("MinimumResources.json").path)
        {
            minimum = try JSONDecoder().decode(
                VMSettings.self,
                from: Data(contentsOf: metadata.appendingPathComponent("MinimumResources.json")))
        }

        let minCPU = max(minimum.cpu, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let maxCPU = min(
            ProcessInfo.processInfo.processorCount,
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let minMemory = Int(
            (max(minimum.memory, VZVirtualMachineConfiguration.minimumAllowedMemorySize) + gib - 1) / gib)
        let maxMemory = Int(
            min(
                ProcessInfo.processInfo.physicalMemory, VZVirtualMachineConfiguration.maximumAllowedMemorySize
            ) / gib)
        guard minCPU <= maxCPU, minMemory <= maxMemory else {
            throw settingsError(
                "This Mac cannot provide the virtual machine’s minimum CPU or memory requirements.")
        }
        return VMResourceLimits(cpu: minCPU...maxCPU, memoryGiB: minMemory...maxMemory)
    }
}
