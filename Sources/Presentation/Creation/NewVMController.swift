import AppKit
import UniformTypeIdentifiers

/// Coordinates the create sheets and returns a complete bundle for the app to register.
@MainActor
enum NewVMController {
    static func create(defaultLocation: URL, mediaCache: InstallerMediaCache) throws -> VMBundle? {
        let alert = NSAlert()
        alert.messageText = "New Virtual Machine"
        let view = NewVMOptionsView()
        alert.accessoryView = view
        alert.addButton(withTitle: "Create…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let title = view.name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let size = Int(view.capacity.stringValue), (8...4096).contains(size) else {
            throw settingsError("Enter a name and a disk capacity from 8 to 4096 GB.")
        }
        let preset = view.preset
        var windowsSetup: WindowsSetupView?
        if preset.distribution == .windows {
            let setup = NSAlert()
            setup.messageText = "Windows Setup"
            let options = WindowsSetupView()
            setup.accessoryView = options
            setup.addButton(withTitle: "Continue")
            setup.addButton(withTitle: "Cancel")
            while true {
                guard setup.runModal() == .alertFirstButtonReturn else { return nil }
                do {
                    try options.validate()
                    break
                } catch { NSAlert(error: error).runModal() }
            }
            windowsSetup = options
        }
        var localISO: URL?
        if !preset.distribution.hasAutomaticInstaller {
            let picker = NSOpenPanel()
            picker.title = preset.distribution.installerSelectionTitle
            picker.message = preset.distribution.installerSelectionMessage
            picker.prompt = "Choose Installer"
            picker.allowedContentTypes = [UTType(filenameExtension: "iso") ?? .diskImage]
            guard picker.runModal() == .OK, let source = picker.url else { return nil }
            localISO = source
        }
        let panel = NSSavePanel()
        panel.title = "Create .asvm Bundle"
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".asvm"
        panel.directoryURL = defaultLocation
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [
            UTType(exportedAs: "nl.theredhead.virtualmac.asvm", conformingTo: .package)
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let bundle = try VMBundle.create(
            at: url, name: title, capacityGB: size, preset: preset, mediaCache: mediaCache)
        if let windowsSetup {
            do {
                var settings = try bundle.resolvedSettings()
                try windowsSetup.apply(to: &settings, id: bundle.id)
                try bundle.save(settings)
            } catch {
                try? WindowsSetupSecret.remove(for: bundle.id)
                try? FileManager.default.removeItem(at: bundle.url)
                throw error
            }
        }
        if let localISO {
            var settings = try bundle.resolvedSettings()
            settings.installationMediaPath = localISO.path
            settings.bootFromInstaller = true
            try bundle.save(settings)
        }
        return bundle
    }
}
