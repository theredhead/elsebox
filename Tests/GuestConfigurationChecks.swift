import Foundation
import Virtualization

@main @MainActor
struct GuestConfigurationChecks {
    static func main() throws {
        let audioSettings = VMSettings(cpu: 2, memory: 4_294_967_296)
        let sound =
            VMAudioConfiguration.devices(resources: audioSettings).first as! VZVirtioSoundDeviceConfiguration
        precondition(sound.streams.count == 1)
        let output = sound.streams.first as! VZVirtioSoundDeviceOutputStreamConfiguration
        precondition(output.sink is VZHostAudioOutputStreamSink)
        var muted = audioSettings
        muted.audioOutputEnabled = false
        precondition(VMAudioConfiguration.devices(resources: muted).isEmpty)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GuestChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for distribution in GuestDistribution.allCases where distribution.isLinux {
            for role in GuestRole.allCases {
                let preset = VMStarterPreset(distribution: distribution, role: role)
                precondition(preset.cpu > 0 && preset.memoryGiB >= 2 && preset.diskGB >= 16)
            }
        }
        let preset = VMStarterPreset(distribution: .debian, role: .minimal)
        let bundle = try VMBundle.create(
            at: root.appendingPathComponent("Debian.asvm"), name: "Debian", capacityGB: preset.diskGB,
            preset: preset, mediaCache: InstallerMediaCache(root: root.appendingPathComponent("Media")))
        var settings = try bundle.resolvedSettings()
        settings.bootFromInstaller = false
        try bundle.save(settings)
        let configuration = try EFIVMConfiguration.make(bundle: bundle, resources: settings)
        if VZVirtualMachine.isSupported { try configuration.validate() }
        precondition(configuration.audioDevices.count == 1)
        precondition(configuration.platform is VZGenericPlatformConfiguration)
        precondition(configuration.bootLoader is VZEFIBootLoader)
        precondition(configuration.graphicsDevices.first is VZVirtioGraphicsDeviceConfiguration)
        precondition(configuration.keyboards.first is VZUSBKeyboardConfiguration)
        precondition(configuration.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
        precondition(configuration.storageDevices.count == 1)
        precondition(
            !FileManager.default.fileExists(atPath: bundle.url.appendingPathComponent("HardwareModel").path))
        let identity = try Data(contentsOf: bundle.url.appendingPathComponent("MachineIdentifier"))
        precondition(VZGenericMachineIdentifier(dataRepresentation: identity) != nil)
        let iso = root.appendingPathComponent("arm64-fixture.iso")
        try Data(repeating: 0, count: 4096).write(to: iso)
        settings.installationMediaPath = iso.path
        settings.bootFromInstaller = true
        try bundle.save(settings)
        let storedISO = try bundle.storedSettings().installationMediaPath!
        precondition(!storedISO.hasPrefix("/"))
        let installerConfiguration = try EFIVMConfiguration.make(
            bundle: bundle, resources: bundle.resolvedSettings())
        if VZVirtualMachine.isSupported { try installerConfiguration.validate() }
        precondition(installerConfiguration.storageDevices.count == 2)
        precondition(installerConfiguration.storageDevices.first is VZUSBMassStorageDeviceConfiguration)
        let restoredIdentity = try Data(contentsOf: bundle.url.appendingPathComponent("MachineIdentifier"))
        precondition(identity == restoredIdentity)
        let reopened = try VMBundle.open(bundle.url, mediaCache: bundle.mediaCache)
        precondition(reopened.distribution == .debian)
        let windows = try VMBundle.create(
            at: root.appendingPathComponent("Windows.asvm"), name: "Windows",
            capacityGB: 64, preset: VMStarterPreset(distribution: .windows, role: .desktop),
            mediaCache: bundle.mediaCache)
        var windowsSettings = try windows.resolvedSettings()
        let drivers = root.appendingPathComponent("drivers.iso")
        try Data(repeating: 1, count: 4096).write(to: drivers)
        windowsSettings.installationMediaPath = iso.path
        windowsSettings.driverMediaPath = drivers.path
        windowsSettings.automaticWindowsDrivers = false
        windowsSettings.bootFromInstaller = true
        try windows.save(windowsSettings)
        let windowsStored = try windows.storedSettings()
        precondition(windowsStored.driverMediaPath!.hasPrefix("media://"))
        let windowsResolved = try windows.resolvedSettings()
        let windowsConfiguration = try EFIVMConfiguration.make(bundle: windows, resources: windowsResolved)
        precondition(windowsConfiguration.audioDevices.isEmpty)
        precondition(windowsConfiguration.storageDevices.count == 3)
        precondition(windowsConfiguration.storageDevices[0] is VZUSBMassStorageDeviceConfiguration)
        precondition(windowsConfiguration.storageDevices[1] is VZNVMExpressControllerDeviceConfiguration)
        precondition(windowsConfiguration.storageDevices[2] is VZVirtioBlockDeviceConfiguration)
        var bundledSettings = windowsResolved
        bundledSettings.automaticWindowsDrivers = true
        let bundledConfiguration = try EFIVMConfiguration.make(bundle: windows, resources: bundledSettings)
        precondition(bundledConfiguration.storageDevices.count == 2)
        precondition(bundledConfiguration.storageDevices[0] is VZUSBMassStorageDeviceConfiguration)
        precondition(bundledConfiguration.storageDevices[1] is VZNVMExpressControllerDeviceConfiguration)
        precondition(windowsConfiguration.directorySharingDevices.isEmpty)
        precondition(windowsConfiguration.memoryBalloonDevices.isEmpty)
        precondition(windowsConfiguration.graphicsDevices.first is VZVirtioGraphicsDeviceConfiguration)
        if VZVirtualMachine.isSupported { try windowsConfiguration.validate() }
        var diskBoot = windowsResolved
        diskBoot.bootFromInstaller = false
        let diskOnly = try EFIVMConfiguration.make(bundle: windows, resources: diskBoot)
        precondition(diskOnly.storageDevices.count == 1)
        var unsafeWindows = diskBoot
        unsafeWindows.cpu = 1
        unsafeWindows.memory = 1_073_741_824
        unsafeWindows.audioOutputEnabled = true
        let protectedWindows = try EFIVMConfiguration.make(bundle: windows, resources: unsafeWindows)
        precondition(protectedWindows.cpuCount >= 2)
        precondition(protectedWindows.memorySize >= 4_294_967_296)
        precondition(protectedWindows.audioDevices.isEmpty)
        unsafeWindows.experimentalWindowsAudio = true
        let labWindows = try EFIVMConfiguration.make(bundle: windows, resources: unsafeWindows)
        precondition(labWindows.audioDevices.count == 1)

        precondition(!windows.distribution.isLinux && windows.distribution.usesEFI)
        precondition(windows.distribution.hasAutomaticInstaller)
        print("Passed: experimental Windows EFI structure, shared installer/driver ISOs, disk-only boot")
        print(
            "Passed: Linux presets, EFI/virtio structure, installer attachment, portable ISO, stable generic identity"
        )
        if !VZVirtualMachine.isSupported {
            print("Skipped: framework hardware validation is unavailable in this execution environment.")
        }
    }
}
