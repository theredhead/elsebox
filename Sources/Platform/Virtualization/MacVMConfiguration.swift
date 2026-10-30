import Foundation
import Virtualization

/// Owns macOS identity preparation and construction of its native virtual hardware.
@MainActor
enum MacVMConfiguration {
    private static let gib: UInt64 = 1024 * 1024 * 1024

    static func preparePlatform(using restoreURL: URL, metadata: URL) async throws {
        let restore = try await VZMacOSRestoreImage.image(from: restoreURL)
        guard let requirements = restore.mostFeaturefulSupportedConfiguration else {
            throw settingsError("This restore image is incompatible with this Mac.")
        }
        if FileManager.default.fileExists(atPath: metadata.appendingPathComponent("HardwareModel").path) {
            let savedModel = try Data(contentsOf: metadata.appendingPathComponent("HardwareModel"))
            guard savedModel == requirements.hardwareModel.dataRepresentation else {
                throw settingsError(
                    "This restore image requires a different hardware model. Use the original restore image for this disk, or create a new disk for this installation."
                )
            }
        }
        // Persist before installation, so an interrupted installation can be retried.
        if !FileManager.default.fileExists(atPath: metadata.appendingPathComponent("HardwareModel").path) {
            try requirements.hardwareModel.dataRepresentation.write(
                to: metadata.appendingPathComponent("HardwareModel"), options: .atomic)
        }
        if !FileManager.default.fileExists(atPath: metadata.appendingPathComponent("MachineIdentifier").path)
        {
            try VZMacMachineIdentifier().dataRepresentation.write(
                to: metadata.appendingPathComponent("MachineIdentifier"), options: .atomic)
        }

        let minimum = VMSettings(
            cpu: requirements.minimumSupportedCPUCount, memory: requirements.minimumSupportedMemorySize)
        try JSONEncoder().encode(minimum).write(
            to: metadata.appendingPathComponent("MinimumResources.json"), options: .atomic)
        if !FileManager.default.fileExists(atPath: metadata.appendingPathComponent("AuxiliaryStorage").path) {
            guard
                let model = VZMacHardwareModel(
                    dataRepresentation: try Data(contentsOf: metadata.appendingPathComponent("HardwareModel"))
                )
            else {
                throw settingsError("Invalid saved hardware model.")
            }
            _ = try VZMacAuxiliaryStorage(
                creatingStorageAt: metadata.appendingPathComponent("AuxiliaryStorage"), hardwareModel: model,
                options: [])
        }
    }

    static func make(bundle: VMBundle, resources: VMSettings) throws -> VZVirtualMachineConfiguration {
        let disk = VMDiskStore.disk(for: resources)
        let metadata = VMDiskStore.metadata(for: disk)
        guard
            let model = VZMacHardwareModel(
                dataRepresentation: try Data(contentsOf: metadata.appendingPathComponent("HardwareModel"))),
            model.isSupported,
            let machineID = VZMacMachineIdentifier(
                dataRepresentation: try Data(contentsOf: metadata.appendingPathComponent("MachineIdentifier"))
            )
        else {
            throw settingsError("The saved VM identity is invalid or unsupported on this Mac.")
        }

        let limits = try VMResourceLimits.load(metadata: metadata, distribution: bundle.distribution)
        // Raise preferences to guest minimums and constrain them to this host.
        let cpuCount = min(max(resources.cpu, limits.cpu.lowerBound), limits.cpu.upperBound)
        let memorySize = min(
            max(resources.memory, UInt64(limits.memoryGiB.lowerBound) * gib),
            UInt64(limits.memoryGiB.upperBound) * gib)
        let configuration = VZVirtualMachineConfiguration()
        configuration.cpuCount = cpuCount
        configuration.memorySize = memorySize
        configuration.audioDevices = VMAudioConfiguration.devices(resources: resources)
        configuration.bootLoader = VZMacOSBootLoader()
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = machineID
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(
            contentsOf: metadata.appendingPathComponent("AuxiliaryStorage"))
        configuration.platform = platform
        let attachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
        if #available(macOS 15.0, *) {
            configuration.usbControllers = [VZXHCIControllerConfiguration()]
        }

        let graphics = VZMacGraphicsDeviceConfiguration()
        let displayWidth = resources.displayWidth ?? 1920
        let displayHeight = resources.displayHeight ?? 1080
        try validateDisplay(width: displayWidth, height: displayHeight)
        guard (36...300).contains(resources.pixelsPerInch ?? 72) else {
            throw settingsError("Display density must be between 36 and 300 PPI.")
        }
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: displayWidth,
                heightInPixels: displayHeight,
                pixelsPerInch: resources.pixelsPerInch ?? 72)
        ]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        if resources.useMacTrackpad == true {
            configuration.pointingDevices = [VZMacTrackpadConfiguration()]
        } else {
            configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        }

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
        let shares =
            resources.sharedFolders ?? [
                SharedFolder(
                    name: "Shared", path: bundle.url.appendingPathComponent("Shared").path, readOnly: false)
            ]
        try VMDiskStore.validateShares(shares)
        if !shares.isEmpty {
            let sharing = VZVirtioFileSystemDeviceConfiguration(
                tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            let directories = Dictionary(
                uniqueKeysWithValues: shares.map {
                    ($0.name, VZSharedDirectory(url: URL(fileURLWithPath: $0.path), readOnly: $0.readOnly))
                })
            sharing.share = VZMultipleDirectoryShare(directories: directories)
            configuration.directorySharingDevices = [sharing]
        }
        return configuration
    }

    private static func validateDisplay(width: Int, height: Int) throws {
        guard (640...7680).contains(width), (480...4320).contains(height) else {
            throw settingsError("Display width must be 640–7680 pixels and height must be 480–4320 pixels.")
        }
    }
}
