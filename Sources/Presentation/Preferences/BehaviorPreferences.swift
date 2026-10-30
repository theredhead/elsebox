import AppKit

/// Owns window-start intent, host audio and RDP launch fields without handling VM hardware or installation media.
@MainActor
final class BehaviorPreferences: NSObject {
    let startupView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
    let audioView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
    let remoteView = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
    private let startupMode = NSPopUpButton()
    private let audioOutput = NSButton(
        checkboxWithTitle: "Play guest audio through the host output", target: nil, action: nil)
    private let remoteAddress = NSTextField()
    private let remoteUsername = NSTextField()
    private let isWindows: Bool

    init(settings: VMSettings, isWindows: Bool) {
        self.isWindows = isWindows
        super.init()
        let startup = startupView
        startupMode.addItems(withTitles: ["Always open the display", "Always start headless"])
        startupMode.selectItem(at: settings.startHeadless == true ? 1 : 0)
        startupMode.setAccessibilityLabel("Default startup mode")
        PreferenceForm.field(startupMode, label: "Default startup mode:", y: 285, in: startup)
        startupMode.setFrameSize(NSSize(width: 280, height: 26))

        if !isWindows {
            let audio = audioView
            audioOutput.state = settings.audioOutputEnabled != false ? .on : .off
            audioOutput.frame = NSRect(x: 20, y: 285, width: 510, height: 26)
            audio.addSubview(audioOutput)
            PreferenceForm.note(
                "Uses the host’s default output device. Applies on the next VM start.", y: 240, in: audio)
        } else {
            let remote = remoteView
            remoteAddress.stringValue = settings.remoteDesktopAddress ?? ""
            remoteUsername.stringValue = settings.remoteDesktopUsername ?? ""
            PreferenceForm.field(remoteAddress, label: "Address:", y: 285, in: remote)
            PreferenceForm.field(remoteUsername, label: "Username:", y: 240, in: remote)
            PreferenceForm.button(
                "Connect…", action: #selector(connectRemoteDesktop), target: self, x: 20, y: 175, in: remote)
        }
    }

    func apply(to result: inout VMSettings) {
        result.startHeadless = startupMode.indexOfSelectedItem == 1
        if !isWindows { result.audioOutputEnabled = audioOutput.state == .on }
        result.remoteDesktopAddress = remoteAddress.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
        result.remoteDesktopUsername = remoteUsername.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    @objc private func connectRemoteDesktop() {
        do {
            let address = remoteAddress.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = remoteUsername.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !address.isEmpty, !address.contains(where: { $0.isWhitespace || $0.isNewline }),
                !username.contains(where: { $0.isNewline })
            else { throw settingsError("Enter a Remote Desktop address.") }

            let text = """
                full address:s:\(address)
                username:s:\(username)
                audiomode:i:0
                audiocapturemode:i:0
                redirectclipboard:i:0
                authentication level:i:2
                prompt for credentials:i:1
                """
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "VirtualMac-\(UUID().uuidString).rdp")
            try Data(text.utf8).write(to: url, options: .atomic)
            guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
                throw settingsError("Install Microsoft Windows App to open Remote Desktop connections.")
            }
            NSWorkspace.shared.open(url)
        } catch { NSAlert(error: error).runModal() }
    }
}
