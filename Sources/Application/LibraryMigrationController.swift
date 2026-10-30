import AppKit

/// Owns the legacy-import operation and its busy lifetime, without controlling app menus or session creation.
@MainActor
final class LibraryMigrationController {
    private(set) var isWorking = false
    var messageDidChange: ((String) -> Void)?
    var didFail: ((Error) -> Void)?
    var didFinish: (() -> Void)?

    func migrate(library: VMLibrary) {
        guard !isWorking else { return }
        guard
            library.root != VMDiskStore.directory
                || !NSRunningApplication.runningApplications(withBundleIdentifier: "nl.theredhead.elsebox")
                    .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })
        else {
            didFail?(settingsError("Close the older ElseBox instance before migrating its VM."))
            return
        }
        isWorking = true
        messageDidChange?("Checking the previous VM for migration…")
        let root = library.root
        Task {
            defer {
                isWorking = false
                didFinish?()
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let worker = VMLibrary(root: root)
                    try worker.load()
                    try worker.migrateLegacyIfNeeded(from: root)
                }.value
                try library.load()
                messageDidChange?("")
            } catch {
                messageDidChange?(
                    "Previous VM import deferred. Use File → Import Previous VM after shutting down the old VM."
                )
                didFail?(error)
            }
        }
    }
}
