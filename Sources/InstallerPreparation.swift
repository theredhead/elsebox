import Foundation

/// Coordinates media preparation and the final atomic settings save for app UI callers.
@MainActor
enum InstallerPreparation {
    @discardableResult
    static func save(bundle: VMBundle, settings: Resources) async throws -> Resources {
        let imports =
            [settings.restoreImagePath, settings.installationMediaPath, settings.driverMediaPath].compactMap {
                $0
            }
            .contains { bundle.mediaCache.reference(for: URL(fileURLWithPath: $0)) == nil }
            || settings.diskPath.map { !bundle.contains(URL(fileURLWithPath: $0)) } == true
        let panel =
            InstallerMediaService.needsDownload(bundle: bundle, settings: settings) || imports
            ? InstallerProgressController(name: bundle.name) : nil
        panel?.show()
        defer { panel?.close() }
        let task = Task {
            let ready = try await InstallerMediaService().prepare(bundle: bundle, settings: settings) {
                message, fraction in
                Task { @MainActor in panel?.update(message, fraction: fraction) }
            }
            try Task.checkCancellation()
            panel?.beginSaving()
            try await Task.detached(priority: .userInitiated) { try bundle.save(ready) }.value
            return try bundle.resolvedSettings()
        }
        panel?.onCancel = { task.cancel() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
