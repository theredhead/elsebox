import Foundation
import ObjectiveC
import Virtualization

/// Windows needs PMU emulation and a framebuffer shim before its EFI boot manager.
@MainActor
enum WindowsBootMedia {
    static func enableCPUFeatures(_ platform: VZGenericPlatformConfiguration) throws {
        for name in [
            "_setPerformanceMonitoringUnitEmulationEnabled:", "_setFineGrainedTrapsEmulationEnabled:",
        ] {
            let selector = NSSelectorFromString(name)
            guard platform.responds(to: selector),
                let method = class_getInstanceMethod(type(of: platform), selector)
            else { throw settingsError("This macOS version lacks the CPU emulation Windows requires.") }
            typealias SetFlag = @convention(c) (AnyObject, Selector, Bool) -> Void
            let setFlag = unsafeBitCast(method_getImplementation(method), to: SetFlag.self)
            setFlag(platform, selector, true)
        }
    }

    static func prepare(bundle: VMBundle, resources: VMSettings) async throws -> URL {
        guard let path = resources.installationMediaPath else {
            throw settingsError("Windows installer is missing.")
        }
        let iso = URL(fileURLWithPath: path)
        let key = iso.deletingLastPathComponent().lastPathComponent
        let folder = bundle.mediaCache.root.appendingPathComponent("Windows Bootstrap/\(key)")
        let target = folder.appendingPathComponent("Installer-v1.img")
        let lease = try await bundle.mediaCache.acquire("windows-bootstrap-\(key)")
        defer { withExtendedLifetime(lease) {} }
        if FileManager.default.fileExists(atPath: target.path) {
            return try await workingCopy(target, bundle: bundle, resources: resources)
        }
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("WindowsBootstrap"),
            FileManager.default.isReadableFile(atPath: root.appendingPathComponent("prepare.sh").path)
        else { throw settingsError("Windows bootstrap resources are missing. Rebuild the app.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent("Preparing-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                root.appendingPathComponent("prepare.sh").path, iso.path, temporary.path, root.path,
            ]
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            let output = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw settingsError(
                    "Preparing Windows boot media failed: \(String(decoding: output, as: UTF8.self))")
            }
        }.value
        try FileManager.default.moveItem(at: temporary, to: target)
        return try await workingCopy(target, bundle: bundle, resources: resources)
    }

    static func rememberDrivers(bundle: VMBundle, resources: VMSettings) throws {
        guard let path = resources.driverMediaPath else { return }
        let digest = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        try Data(digest.utf8).write(
            to: bundle.url.appendingPathComponent("WindowsDriverSHA256"), options: .atomic)
    }

    static func installationSucceeded(bundle: VMBundle) async throws -> Bool {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("WindowsBootstrap") else {
            return false
        }
        let image = bundle.url.appendingPathComponent("WindowsBootstrap.img")
        guard FileManager.default.fileExists(atPath: image.path) else { return false }
        for attempt in 0..<4 {
            let result: (Int32, String) = try await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [root.appendingPathComponent("read-state.sh").path, image.path]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                try process.run()
                let output = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                return (process.terminationStatus, String(decoding: output, as: UTF8.self))
            }.value
            if result.0 == 0 {
                if result.1.trimmingCharacters(in: .whitespacesAndNewlines) == "installed" { return true }
                if result.1.contains("DEPLOYMENT FAILED") { throw settingsError(result.1) }
                return false
            }
            if attempt < 3 { try await Task.sleep(nanoseconds: 1_000_000_000) }
        }
        throw settingsError("Could not read Windows deployment status after shutdown.")
    }

    private static func workingCopy(_ source: URL, bundle: VMBundle, resources: VMSettings) async throws
        -> URL
    {
        let target = bundle.url.appendingPathComponent("WindowsBootstrap.img")
        if !FileManager.default.fileExists(atPath: target.path) {
            try HostFileOperations.copyPreservingAllocation(from: source, to: target)
        }
        let bundled = resources.automaticWindowsDrivers == true
        let driverKey =
            bundled
            ? "bundled-virtio-0.1.302"
            : resources.driverMediaPath.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().lastPathComponent
            } ?? "missing"
        let marker = bundle.url.appendingPathComponent("WindowsPE-v13-\(driverKey).ready")
        if !FileManager.default.fileExists(atPath: marker.path) {
            guard let root = Bundle.main.resourceURL?.appendingPathComponent("WindowsBootstrap"),
                let driverSource = bundled ? "bundled" : resources.driverMediaPath
            else { throw settingsError("Use the bundled Windows drivers or select a driver ISO.") }
            try await Task.detached(priority: .userInitiated) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = [
                    root.appendingPathComponent("prepare-pe.sh").path, target.path, driverSource, root.path,
                ]
                let errors = Pipe()
                process.standardError = errors
                process.standardOutput = FileHandle.nullDevice
                try process.run()
                let output = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    throw settingsError("Preparing WinPE failed: \(String(decoding: output, as: UTF8.self))")
                }
            }.value
            try Data("13".utf8).write(to: marker, options: .atomic)
        }
        if resources.windowsUnattended == true {
            try await prepareUnattended(bundle: bundle, resources: resources, image: target)
        }
        return target
    }

    private static func prepareUnattended(bundle: VMBundle, resources: VMSettings, image: URL) async throws {
        guard resources.windowsAcceptedLicense == true, let username = resources.windowsUsername,
            let culture = WindowsCulture(rawValue: resources.windowsCulture ?? "en-US"),
            let root = Bundle.main.resourceURL?.appendingPathComponent("WindowsBootstrap")
        else { throw settingsError("Windows automatic setup is incomplete. Create a new Windows VM.") }
        let password = try WindowsSetupSecret.read(for: bundle.id)
        let answer = try WindowsAnswerFile.make(
            username: username, password: password, culture: culture,
            enableRDP: resources.windowsEnableRDP == true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WindowsSetup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let answerURL = temporary.appendingPathComponent("Unattend.xml")
        try Data(answer.utf8).write(to: answerURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: answerURL.path)
        let options: [String: Bool] = [
            "enableRDP": resources.windowsEnableRDP == true,
            "enableAudio": resources.experimentalWindowsAudio == true,
        ]
        try JSONSerialization.data(withJSONObject: options).write(
            to: temporary.appendingPathComponent("Options.json"))
        for name in ["Prepare-Windows.ps1", "Finalize-Windows.ps1", "RegistryPolicy.ps1"] {
            try FileManager.default.copyItem(
                at: root.appendingPathComponent(name), to: temporary.appendingPathComponent(name))
        }
        if resources.experimentalWindowsAudio == true {
            let drivers = root.appendingPathComponent("AudioDrivers")
            for file in try FileManager.default.contentsOfDirectory(
                at: drivers, includingPropertiesForKeys: nil)
            {
                try FileManager.default.copyItem(
                    at: file, to: temporary.appendingPathComponent(file.lastPathComponent))
            }
            try Data().write(to: temporary.appendingPathComponent("EnableAudio"))
        }
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                root.appendingPathComponent("provision-media.sh").path, image.path, temporary.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw settingsError("Could not prepare private Windows setup media.")
            }
        }.value
    }
}
