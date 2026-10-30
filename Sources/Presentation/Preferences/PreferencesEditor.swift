import AppKit

/// Composes independent preference pages and collects a validated settings snapshot for the caller to save.
@MainActor
final class PreferencesEditor: NSView {
    private let original: VMSettings
    private let hardware: HardwarePreferences
    private let behavior: BehaviorPreferences
    private let storage: StoragePreferences
    private let folders: SharedFoldersPreferences?

    init(
        settings: VMSettings, cpuLimits: ClosedRange<Int>, memoryLimits: ClosedRange<Int>,
        hostAspectRatio: Double, bundle: VMBundle? = nil
    ) {
        original = settings
        let distribution = bundle?.distribution ?? .macOS
        hardware = HardwarePreferences(
            settings: settings, cpuLimits: cpuLimits, memoryLimits: memoryLimits,
            hostAspectRatio: hostAspectRatio, distribution: distribution)
        behavior = BehaviorPreferences(settings: settings, isWindows: distribution == .windows)
        storage = StoragePreferences(settings: settings, bundle: bundle)
        folders = distribution == .windows ? nil : SharedFoldersPreferences(settings: settings)
        super.init(frame: NSRect(x: 0, y: 0, width: 580, height: 410))
        let tabs = NSTabView(frame: bounds)
        tabs.autoresizingMask = [.width, .height]
        addSubview(tabs)
        addTab("Hardware", view: hardware.view, to: tabs)
        addTab("Startup", view: behavior.startupView, to: tabs)
        addTab(
            distribution == .windows ? "Remote Desktop" : "Audio",
            view: distribution == .windows ? behavior.remoteView : behavior.audioView, to: tabs)
        addTab("Storage & Installation", view: storage.storageView, to: tabs)
        if distribution == .windows && !storage.protectsStartupDisk {
            addTab("Windows Drivers", view: storage.driverView, to: tabs)
        }
        if let folders { addTab("Shared Folders", view: folders.view, to: tabs) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func settings() throws -> VMSettings {
        var result = original
        try hardware.apply(to: &result)
        behavior.apply(to: &result)
        try storage.apply(to: &result)
        if let folders {
            try folders.apply(to: &result)
        } else {
            result.sharedFolders = original.sharedFolders ?? []
        }
        return result
    }

    private func addTab(_ title: String, view: NSView, to tabs: NSTabView) {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        item.view = view
        tabs.addTabViewItem(item)
    }
}
