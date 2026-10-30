import AppKit

/// New-machine provisioning; credentials are never placed in Resources.json.
@MainActor
final class WindowsSetupView: NSView {
    private let automatic = NSButton(
        checkboxWithTitle: "Set up Windows automatically", target: nil, action: nil)
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private let confirmation = NSSecureTextField()
    private let culture = NSPopUpButton()
    private let remote = NSButton(checkboxWithTitle: "Enable Remote Desktop", target: nil, action: nil)
    private let audio = NSButton(
        checkboxWithTitle: "Experimental audio (test-signed driver)", target: nil, action: nil)
    private let license = NSButton(
        checkboxWithTitle: "I accept the Windows license terms", target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 510, height: 360))
        automatic.state = .on
        remote.state = .on
        username.stringValue = "tester"
        culture.addItems(withTitles: WindowsCulture.allCases.map { $0.title })
        for (title, control, y) in [
            ("Language / region:", culture as NSControl, 270.0),
            ("Local username:", username, 225.0), ("Password:", password, 180.0),
            ("Confirm password:", confirmation, 135.0),
        ] {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + 3, width: 150, height: 24)
            control.frame = NSRect(x: 160, y: y, width: 340, height: 26)
            control.setAccessibilityLabel(title)
            addSubview(label)
            addSubview(control)
        }
        for (control, y) in [(automatic, 315.0), (remote, 95.0), (audio, 65.0), (license, 25.0)] {
            control.frame = NSRect(x: 0, y: y, width: 400, height: 26)
            addSubview(control)
        }
        let terms = NSButton(title: "Read…", target: self, action: #selector(readTerms))
        terms.frame = NSRect(x: 405, y: 25, width: 90, height: 26)
        addSubview(terms)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func validate() throws {
        guard automatic.state == .on else { return }
        guard license.state == .on else {
            throw settingsError("Accept the Windows license terms to use automatic setup.")
        }
        guard password.stringValue == confirmation.stringValue else {
            throw settingsError("The passwords do not match.")
        }
        try WindowsAnswerFile.validateUsername(
            username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func apply(to settings: inout Resources, id: UUID) throws {
        try validate()
        let selectedCulture = WindowsCulture.allCases[culture.indexOfSelectedItem]
        settings.windowsCulture = selectedCulture.rawValue
        guard automatic.state == .on else { return }
        guard license.state == .on else {
            throw settingsError("Accept the Windows license terms to use automatic setup.")
        }
        guard password.stringValue == confirmation.stringValue else {
            throw settingsError("The passwords do not match.")
        }
        let name = username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        try WindowsAnswerFile.validateUsername(name)
        try WindowsSetupSecret.save(password.stringValue, for: id)
        settings.windowsUnattended = true
        settings.windowsUsername = name
        settings.windowsEnableRDP = remote.state == .on
        settings.windowsAcceptedLicense = true
        settings.experimentalWindowsAudio = audio.state == .on
        settings.audioOutputEnabled = false
        settings.remoteDesktopUsername = ".\\\(name)"
        password.stringValue = ""
        confirmation.stringValue = ""
    }

    @objc private func readTerms() {
        NSWorkspace.shared.open(URL(string: "https://www.microsoft.com/en-us/Useterms/")!)
    }
}
