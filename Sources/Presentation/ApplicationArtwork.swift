import AppKit

/// Owns application/About and Finder bundle artwork so icon installation is independent of application routing.
@MainActor
final class ApplicationArtwork {
    private var appliedURLs: Set<URL> = []

    var icon: NSImage? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        return NSImage(contentsOf: resources.appendingPathComponent("AppIcon.icns"))
    }

    func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "Copyright © theredhead 2026"
        ]
        if let icon = icon { options[.applicationIcon] = icon }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    func apply(to bundles: [VMBundle]) {
        guard let icon else { return }
        for bundle in bundles where !appliedURLs.contains(bundle.url) {
            if NSWorkspace.shared.setIcon(icon, forFile: bundle.url.path, options: []) {
                appliedURLs.insert(bundle.url)
            }
        }
    }
}
