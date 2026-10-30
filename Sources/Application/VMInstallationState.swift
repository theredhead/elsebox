import Foundation

/// Commits successful guest provisioning and releases media references without altering cached installer files.
@MainActor
enum VMInstallationState {
    static func releaseMedia(bundle: VMBundle) throws {
        var settings = try bundle.resolvedSettings()
        if bundle.distribution == .windows {
            try WindowsBootMedia.rememberDrivers(bundle: bundle, resources: settings)
        }
        settings.bootFromInstaller = false
        settings.restoreImagePath = nil
        settings.installationMediaPath = nil
        settings.driverMediaPath = nil
        try bundle.save(settings)
    }

    static func finishWindowsDeployment(bundle: VMBundle) async throws -> Bool {
        guard try await WindowsBootMedia.installationSucceeded(bundle: bundle) else { return false }

        var settings = try bundle.resolvedSettings()
        settings.bootFromInstaller = false
        if settings.windowsUnattended == true {
            settings.audioOutputEnabled = settings.experimentalWindowsAudio == true
        }
        try WindowsBootMedia.rememberDrivers(bundle: bundle, resources: settings)
        settings.installationMediaPath = nil
        settings.driverMediaPath = nil
        try bundle.save(settings)
        if settings.windowsUnattended == true {
            try WindowsSetupSecret.remove(for: bundle.id)
        }
        return true
    }
}
