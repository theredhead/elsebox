import Foundation
import Virtualization

/// Shared EFI/virtio backend for Linux and experimental Windows ARM guests.
@MainActor
enum EFIVMConfiguration {
    static func make(bundle: VMBundle, resources: Resources) throws -> VZVirtualMachineConfiguration {
        let disk = VMDiskStore.disk(for: resources)
        let metadata = VMDiskStore.metadata(for: disk)
        let identityURL = metadata.appendingPathComponent("MachineIdentifier")
        if !FileManager.default.fileExists(atPath: identityURL.path) {
            try VZGenericMachineIdentifier().dataRepresentation.write(to: identityURL, options: .atomic)
        }
        guard let identity = VZGenericMachineIdentifier(dataRepresentation: try Data(contentsOf: identityURL))
        else {
            throw settingsError("Invalid EFI machine identity.")
        }
        let installingWindows = bundle.distribution == .windows && resources.bootFromInstaller != false
        let firmwareURL = metadata.appendingPathComponent(
            installingWindows ? "WindowsInstallerEFIVariableStore" : "EFIVariableStore")
        let firmware: VZEFIVariableStore
        if FileManager.default.fileExists(atPath: firmwareURL.path) {
            firmware = VZEFIVariableStore(url: firmwareURL)
        } else {
            firmware = try VZEFIVariableStore(creatingVariableStoreAt: firmwareURL)
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = identity
        if bundle.distribution == .windows { try WindowsBootMedia.enableCPUFeatures(platform) }
        let boot = VZEFIBootLoader()
        boot.variableStore = firmware
        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.audioDevices =
            bundle.distribution == .windows && resources.experimentalWindowsAudio != true
            ? [] : VMAudioConfiguration.devices(resources: resources)
        configuration.bootLoader = boot
        configuration.cpuCount = min(
            max(
                resources.cpu,
                max(
                    bundle.distribution == .windows ? 2 : 1,
                    VZVirtualMachineConfiguration.minimumAllowedCPUCount)),
            min(ProcessInfo.processInfo.processorCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount))
        configuration.memorySize = min(
            max(
                resources.memory,
                max(
                    bundle.distribution == .windows ? 4_294_967_296 : 0,
                    VZVirtualMachineConfiguration.minimumAllowedMemorySize)),
            min(
                ProcessInfo.processInfo.physicalMemory, VZVirtualMachineConfiguration.maximumAllowedMemorySize
            ))
        var disks: [VZStorageDeviceConfiguration] = []
        if resources.bootFromInstaller != false {
            guard let mediaPath = resources.installationMediaPath else {
                throw settingsError("Select an ARM64 installer ISO.")
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: mediaPath), readOnly: bundle.distribution != .windows)
            disks.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        let startupAttachment = try VZDiskImageStorageDeviceAttachment(url: disk, readOnly: false)
        if bundle.distribution == .windows {
            disks.append(VZNVMExpressControllerDeviceConfiguration(attachment: startupAttachment))
        } else {
            disks.append(VZVirtioBlockDeviceConfiguration(attachment: startupAttachment))
        }
        if bundle.distribution == .windows, resources.bootFromInstaller != false,
            resources.automaticWindowsDrivers != true, let path = resources.driverMediaPath
        {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: URL(fileURLWithPath: path), readOnly: true)
            disks.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }
        configuration.storageDevices = disks
        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [
            VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: resources.displayWidth ?? 1920,
                heightInPixels: resources.displayHeight ?? 1080)
        ]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZUSBKeyboardConfiguration()]
        configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]
        if bundle.distribution.isLinux {
            configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
            configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        }
        if #available(macOS 15.0, *) { configuration.usbControllers = [VZXHCIControllerConfiguration()] }
        let shares = resources.sharedFolders ?? []
        try VMDiskStore.validateShares(shares)
        if bundle.distribution.isLinux && !shares.isEmpty {
            let sharing = VZVirtioFileSystemDeviceConfiguration(tag: "shared")
            sharing.share = VZMultipleDirectoryShare(
                directories: Dictionary(
                    uniqueKeysWithValues: shares.map {
                        (
                            $0.name,
                            VZSharedDirectory(url: URL(fileURLWithPath: $0.path), readOnly: $0.readOnly)
                        )
                    }))
            configuration.directorySharingDevices = [sharing]
        }
        return configuration
    }
}
