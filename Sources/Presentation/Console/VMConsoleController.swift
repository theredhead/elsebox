import AppKit

/// Keeps a reusable console window alive while its VM runs headlessly, and forwards user intent to its session.
@MainActor
final class VMConsoleController: NSObject, NSWindowDelegate {
    let window: VMWindow
    let content: VMConsoleContentView
    let presentation: VMWindowPresentation

    var didActivate: (() -> Void)?
    var shouldClose: (() -> Bool)?
    var didClose: (() -> Void)?

    var hostAspectRatio: Double {
        if presentation.usesEntireDisplay || window.styleMask.contains(.fullScreen),
            content.vmView.bounds.width > 0, content.vmView.bounds.height > 0
        {
            return content.vmView.bounds.width / content.vmView.bounds.height
        }

        let size = (window.screen ?? NSScreen.main)?.frame.size ?? NSSize(width: 1920, height: 1080)
        return size.width / size.height
    }

    init(bundle: VMBundle) {
        content = VMConsoleContentView(bundle: bundle)
        window = VMWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        presentation = VMWindowPresentation(window: window, viewport: content.vmView)
        super.init()
        window.title = bundle.name
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.delegate = self
        window.center()
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    func hide() { window.orderOut(nil) }

    func close() { window.close() }

    func windowDidBecomeKey(_ notification: Notification) { didActivate?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose?() ?? true }

    func windowWillClose(_ notification: Notification) { didClose?() }

    func windowDidEnterFullScreen(_ notification: Notification) {
        presentation.windowDidEnterFullScreen(notification)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        presentation.windowDidExitFullScreen(notification)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        presentation.windowDidFailToExitFullScreen(window)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        presentation.windowDidChangeScreen(notification)
    }

    func windowDidResize(_ notification: Notification) { presentation.windowDidResize(notification) }
}
