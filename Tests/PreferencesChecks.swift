import AppKit

@main
struct PreferencesChecks {
    @MainActor
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PreferencesChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = InstallerMediaCache(root: root.appendingPathComponent("Media"))
        for distribution in [GuestDistribution.macOS, .ubuntu, .windows] {
            let bundle = try VMBundle.create(
                at: root.appendingPathComponent("\(distribution.rawValue).asvm"),
                name: "Test", capacityGB: 8,
                preset: VMStarterPreset(distribution: distribution, role: .desktop), mediaCache: cache)
            var settings = try bundle.resolvedSettings()
            settings.cpu = 3
            settings.memory = 6 * 1_073_741_824
            settings.displayWidth = 1440
            settings.displayHeight = 900
            settings.pixelsPerInch = 100
            settings.sharedFolders = []
            settings.startHeadless = true
            settings.remoteDesktopAddress = "192.0.2.10"
            settings.remoteDesktopUsername = "tester"
            if CommandLine.arguments.contains("--native-ui") {
                verifyWindowComposition(bundle: bundle, cache: cache)
            }
            let boot = try VMBootSettings.make(
                preferences: settings, distribution: distribution, hostAspectRatio: 16.0 / 10)
            if distribution == .windows {
                precondition(
                    boot.displayWidth == 1024 && boot.displayHeight == 768
                        && boot.keepHostAspectRatio == false)
                precondition(settings.displayWidth == 1440 && settings.displayHeight == 900)
            }
            let result = try PreferencesEditor(
                settings: settings, cpuLimits: 1...8, memoryLimits: 1...16,
                hostAspectRatio: 16.0 / 10, bundle: bundle
            ).settings()
            precondition(result.cpu == 3 && result.memory == settings.memory && result.startHeadless == true)
            precondition(result.sharedFolders == [])
            if distribution == .windows {
                precondition(result.remoteDesktopAddress == settings.remoteDesktopAddress)
                precondition(
                    result.displayWidth == 1024 && result.displayHeight == 768 && result.pixelsPerInch == 72)
                precondition(result.useMacTrackpad == false)
                settings.bootFromInstaller = false
                let installed = try PreferencesEditor(
                    settings: settings, cpuLimits: 1...8, memoryLimits: 1...16,
                    hostAspectRatio: 16.0 / 10, bundle: bundle
                ).settings()
                precondition(installed.diskPath == settings.diskPath && installed.bootFromInstaller == false)
                precondition(installed.automaticWindowsDrivers == settings.automaticWindowsDrivers)
            } else {
                precondition(
                    result.displayWidth == 1440 && result.displayHeight == 900 && result.pixelsPerInch == 100)
            }
        }
        if CommandLine.arguments.contains("--native-ui") {
            verifyMenuRouting()
            print("Passed: native library/console construction and menu command routing")
        }
        try await verifyFailedBootReleasesLease(root: root, cache: cache)
        print("Passed: preference composition, Windows boot protection, and failed-boot lease release")
    }
    @MainActor
    private static func verifyWindowComposition(bundle: VMBundle, cache: InstallerMediaCache) {
        let library = LibraryWindowController()
        library.mediaURL = cache.root
        library.reload([bundle], select: bundle.id)
        library.window.contentView?.layoutSubtreeIfNeeded()
        precondition(library.selected?.id == bundle.id)
        library.window.close()

        let console = VMConsoleController(bundle: bundle)
        precondition(console.window.contentView === console.content)
        console.content.setStatusBarVisible(false)
        precondition(!console.content.statusBarVisible)
        console.content.setStatusBarVisible(true)
        precondition(console.content.statusBarVisible)
        console.window.close()
    }

    @MainActor
    private static func verifyMenuRouting() {
        let menus = ApplicationMenus()
        var invoked = false
        menus.canPerform = { _ in true }
        menus.onCommand = { if case .showLibrary = $0 { invoked = true } }
        menus.install()
        let windowMenu = NSApp.windowsMenu!
        let index = windowMenu.items.firstIndex { $0.keyEquivalent == "0" }!
        windowMenu.performActionForItem(at: index)
        precondition(invoked)
    }

    @MainActor
    private static func verifyFailedBootReleasesLease(root: URL, cache: InstallerMediaCache) async throws {
        let bundle = try VMBundle.create(
            at: root.appendingPathComponent("Failed Boot.asvm"), name: "Failed Boot",
            capacityGB: 8, preset: VMStarterPreset(distribution: .windows, role: .desktop), mediaCache: cache)
        var settings = try bundle.resolvedSettings()
        settings.bootFromInstaller = false
        try bundle.save(settings)
        settings.diskPath = root.appendingPathComponent("missing.img").path
        let execution = VMExecutionController(bundle: bundle)
        var failed = false
        execution.didFail = { _ in failed = true }
        execution.start(settings: settings)
        let deadline = Date().addingTimeInterval(5)
        while execution.isActive, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(failed && !execution.isActive)
        let releasedLease = try VMLease(directory: bundle.url)
        withExtendedLifetime(releasedLease) {}
    }
}
