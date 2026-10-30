import AppKit

/// Bootstrap for temporary GUI probes. Install before showing any test windows.
@MainActor
enum HelperAppLifecycle {
    private static var closeObserver: NSObjectProtocol?

    static func install(name: String) {
        let app = NSApplication.shared
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: name)
        let quit = NSMenuItem(
            title: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        app.mainMenu = menu
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { notification in
            let closingWindow = notification.object as? NSWindow
            Task { @MainActor in
                let remaining = app.windows.contains { $0 !== closingWindow && $0.isVisible }
                if !remaining { app.terminate(nil) }
            }
        }
    }
}
