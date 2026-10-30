import AppKit

/// Keeps preference validation and retrying its sheet separate from runtime/session state.
@MainActor
enum VMSettingsController {
    static func edit(bundle: VMBundle, hostAspectRatio: Double) throws -> Bool {
        let resources = try bundle.resolvedSettings()
        let limits = try VMResourceLimits.load(
            metadata: VMDiskStore.metadata(for: VMDiskStore.disk(for: resources)),
            distribution: bundle.distribution)
        let editor = PreferencesEditor(
            settings: resources, cpuLimits: limits.cpu,
            memoryLimits: limits.memoryGiB, hostAspectRatio: hostAspectRatio, bundle: bundle)
        let alert = NSAlert()
        alert.messageText = "\(bundle.name) — Configuration"
        alert.informativeText = "Changes apply on the next start."
        alert.accessoryView = editor
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        // Leave all controls intact when validation fails.
        while alert.runModal() == .alertFirstButtonReturn {
            do {
                let updated = try editor.settings()
                try InstallerPreparation.begin(bundle: bundle, settings: updated)
                return true
            } catch { NSAlert(error: error).runModal() }
        }
        return false
    }
}
