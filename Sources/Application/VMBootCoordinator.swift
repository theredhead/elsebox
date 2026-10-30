import AppKit
import UniformTypeIdentifiers
import Virtualization

/// Prepares one boot's media/hardware and completes first installation before returning a running VM.
/// Reports progress and created runtimes without owning windows, session leases or later stop operations.
@MainActor
final class VMBootCoordinator {
    private let bundle: VMBundle

    var statusDidChange: ((String) -> Void)?
    var stateDidChange: (() -> Void)?
    var machineDidChange: ((VMRuntime) -> Void)?
    var installerDidChange: ((VZMacOSInstaller?) -> Void)?

    init(bundle: VMBundle) { self.bundle = bundle }

    func start(resources: VMSettings) async throws -> VMRuntime {
        guard VZVirtualMachine.isSupported else {
            throw settingsError("Virtualization is unavailable on this host.")
        }

        let settings = try await prepareSettings(resources)
        let restoreURL = try await prepareMacPlatform(settings)
        let configuration = try makeConfiguration(settings)
        var runtime = publishRuntime(settings: settings, configuration: configuration)

        if let restoreURL { runtime = try await installMacOS(runtime, from: restoreURL) }

        statusDidChange?("Starting \(bundle.distribution.title)…")
        if runtime.machine.state == .stopped { try await runtime.machine.start() }
        statusDidChange?("\(bundle.distribution.title) — Running")
        if !bundle.distribution.usesEFI || settings.bootFromInstaller == false {
            try VMInstallationState.releaseMedia(bundle: bundle)
        }
        return runtime
    }

    private func prepareSettings(_ initial: VMSettings) async throws -> VMSettings {
        var settings = initial
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        try VMDiskStore.validate(VMDiskStore.disk(for: settings))
        if settings.sharedFolders == nil {
            try FileManager.default.createDirectory(
                at: bundle.url.appendingPathComponent("Shared"), withIntermediateDirectories: true)
        }
        if bundle.distribution.hasAutomaticInstaller
            && InstallerMediaService.needsDownload(bundle: bundle, settings: settings)
        {
            settings = try await InstallerPreparation.save(bundle: bundle, settings: settings)
        }
        if bundle.distribution.usesEFI, settings.bootFromInstaller != false,
            settings.installationMediaPath == nil
        {
            settings = try await chooseEFIInstaller(settings)
        }
        if bundle.distribution == .windows, settings.bootFromInstaller != false {
            statusDidChange?("Preparing Windows bootstrap media…")
            settings.installationMediaPath = try await WindowsBootMedia.prepare(
                bundle: bundle, resources: settings
            ).path
        }
        return settings
    }

    private func chooseEFIInstaller(_ initial: VMSettings) async throws -> VMSettings {
        let panel = NSOpenPanel()
        panel.title = bundle.distribution.installerSelectionTitle
        panel.message = bundle.distribution.installerSelectionMessage
        panel.prompt = "Choose Installer"
        panel.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
        guard panel.runModal() == .OK, let source = panel.url else { throw CancellationError() }

        var settings = initial
        settings.installationMediaPath = source.path
        settings.bootFromInstaller = true
        return try await InstallerPreparation.save(bundle: bundle, settings: settings)
    }

    private func prepareMacPlatform(_ settings: VMSettings) async throws -> URL? {
        let metadata = VMDiskStore.metadata(for: VMDiskStore.disk(for: settings))
        guard !bundle.distribution.usesEFI,
            !FileManager.default.fileExists(atPath: metadata.appendingPathComponent("Installed").path)
        else { return nil }
        guard let path = settings.restoreImagePath, FileManager.default.isReadableFile(atPath: path)
        else {
            throw settingsError(
                "The macOS restore image is unavailable. Save this VM’s configuration to prepare it again.")
        }

        let url = URL(fileURLWithPath: path)
        try await MacVMConfiguration.preparePlatform(using: url, metadata: metadata)
        return url
    }

    private func makeConfiguration(_ settings: VMSettings) throws -> VZVirtualMachineConfiguration {
        let configuration =
            try bundle.distribution.usesEFI
            ? EFIVMConfiguration.make(bundle: bundle, resources: settings)
            : MacVMConfiguration.make(bundle: bundle, resources: settings)
        try configuration.validate()
        return configuration
    }

    private func publishRuntime(settings: VMSettings, configuration: VZVirtualMachineConfiguration)
        -> VMRuntime
    {
        let media =
            bundle.distribution.usesEFI && settings.bootFromInstaller != false
            ? settings.installationMediaPath.map { URL(fileURLWithPath: $0) } : nil
        let runtime = VMRuntime(
            machine: VZVirtualMachine(configuration: configuration), configuration: configuration,
            settings: settings, installationMedia: media)
        machineDidChange?(runtime)
        return runtime
    }

    private func installMacOS(_ runtime: VMRuntime, from restoreURL: URL) async throws -> VMRuntime {
        statusDidChange?("Installing macOS… This may take a while.")
        let installer = VZMacOSInstaller(virtualMachine: runtime.machine, restoringFromImageAt: restoreURL)
        installerDidChange?(installer)
        stateDidChange?()
        try await installer.install()
        installerDidChange?(nil)
        let metadata = VMDiskStore.metadata(for: runtime.bootDisk)
        try Data().write(to: metadata.appendingPathComponent("Installed"), options: .atomic)
        try VMInstallationState.releaseMedia(bundle: bundle)
        try await retireRestoreMachine(runtime.machine)
        let normalBoot = publishRuntime(settings: runtime.settings, configuration: runtime.configuration)
        stateDidChange?()
        return normalBoot
    }

    private func retireRestoreMachine(_ machine: VZVirtualMachine) async throws {
        // Restore shutdown callbacks must never tear down the first normal-boot runtime.
        machine.delegate = nil
        if machine.canStop { try await machine.stop() }

        let deadline = Date().addingTimeInterval(30)
        while machine.state == .stopping, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        guard machine.state == .stopped else {
            throw settingsError(
                "macOS installation completed, but the installer VM has not stopped. Start this VM again to boot the installed system."
            )
        }
    }
}
