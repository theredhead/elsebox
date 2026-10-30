import AppKit

/// Owns native/borderless full-screen transitions so VM execution is independent of window geometry.
@MainActor
final class VMWindowPresentation {
    private let window: NSWindow
    private let vmView: NSView
    private(set) var usesEntireDisplay = false
    private var enterEntireDisplayAfterNativeExit = false
    private var savedWindowFrame: NSRect?
    private var savedPresentationOptions: NSApplication.PresentationOptions = []

    var didChange: (() -> Void)?
    var viewportDidChange: (() -> Void)?
    var willEnterEntireDisplay: (() -> Void)?

    init(window: NSWindow, viewport: NSView) {
        self.window = window
        vmView = viewport
    }

    func exitEntireDisplayIfNeeded() {
        if usesEntireDisplay { leaveEntireDisplay() }
    }

    func toggleEntireDisplay(_ sender: Any? = nil) {
        if usesEntireDisplay {
            leaveEntireDisplay()
        } else if window.styleMask.contains(.fullScreen) {
            enterEntireDisplayAfterNativeExit = true
            window.toggleFullScreen(nil)
        } else {
            enterEntireDisplay()
        }
    }

    func toggleNativeFullScreen(_ sender: Any? = nil) {
        if usesEntireDisplay {
            leaveEntireDisplay()
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.window.toggleFullScreen(nil)
            }
        } else {
            window.toggleFullScreen(nil)
        }
    }

    private func enterEntireDisplay() {
        guard let screen = window.screen ?? NSScreen.main else { return }
        willEnterEntireDisplay?()
        savedWindowFrame = window.frame
        savedPresentationOptions = NSApp.presentationOptions
        usesEntireDisplay = true
        didChange?()
        NSApp.presentationOptions =
            savedPresentationOptions
            .subtracting([.hideDock, .hideMenuBar])
            .union([.autoHideDock, .autoHideMenuBar])
        window.styleMask = [.borderless]
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(vmView)
        viewportDidChange?()
    }

    private func leaveEntireDisplay() {
        usesEntireDisplay = false
        didChange?()
        NSApp.presentationOptions = savedPresentationOptions
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        if let frame = savedWindowFrame { window.setFrame(frame, display: true) }
        window.makeKeyAndOrderFront(nil)
        viewportDidChange?()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        didChange?()
        viewportDidChange?()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        didChange?()
        if enterEntireDisplayAfterNativeExit {
            enterEntireDisplayAfterNativeExit = false
            // Let AppKit finish restoring normal presentation before entering borderless mode.
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.enterEntireDisplay()
            }
        } else {
            viewportDidChange?()
        }
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        enterEntireDisplayAfterNativeExit = false
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if usesEntireDisplay, let screen = window.screen { window.setFrame(screen.frame, display: true) }
        viewportDidChange?()
    }

    func windowDidResize(_ notification: Notification) { viewportDidChange?() }
}
