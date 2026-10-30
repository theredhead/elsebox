import Foundation
import Virtualization

struct SharedFolder: Codable, Equatable {
    var name: String
    var path: String
    var readOnly: Bool
}

/// Optional fields preserve compatibility with earlier Resources.json files.
struct Resources: Codable {
    var cpu: Int
    var memory: UInt64
    var displayWidth: Int? = nil
    var displayHeight: Int? = nil
    var keepHostAspectRatio: Bool? = nil
    var pixelsPerInch: Int? = nil
    var useMacTrackpad: Bool? = nil
    var showsStatusBar: Bool? = nil
    var audioOutputEnabled: Bool? = nil
    var experimentalWindowsAudio: Bool? = nil
    var windowsCulture: String? = nil
    var windowsUnattended: Bool? = nil
    var windowsUsername: String? = nil
    var windowsEnableRDP: Bool? = nil
    var windowsAcceptedLicense: Bool? = nil
    var remoteDesktopAddress: String? = nil
    var remoteDesktopUsername: String? = nil
    var diskPath: String? = nil
    var restoreImagePath: String? = nil
    var automaticWindowsDrivers: Bool? = nil
    var driverMediaPath: String? = nil
    var installationMediaPath: String? = nil
    var bootFromInstaller: Bool? = nil
    var sharedFolders: [SharedFolder]? = nil
}

func settingsError(_ message: String) -> NSError {
    NSError(domain: "nl.theredhead.virtualmac", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
