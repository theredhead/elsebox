import AppKit

/// Names app-level menu intent without exposing selectors or menu layout to application orchestration.
enum ApplicationCommand {
    case about
    case configure
    case newVM
    case openVM
    case showLibrary
    case importPrevious
    case toggleStatus
    case toggleEntireDisplay
    case toggleFullScreen
    case start
    case startHeadless
    case shutDown
    case forceStop
    case bootFromDisk
}

/// Owns native menu construction and checked/visible items; the application supplies routing and availability.
@MainActor
final class ApplicationMenus: NSObject, NSMenuItemValidation {
    private var statusItem: NSMenuItem!
    private var entireDisplayItem: NSMenuItem!
    private var nativeFullScreenItem: NSMenuItem!
    private var disksItem: NSMenuItem!
    private var devicesItem: NSMenuItem!

    var onCommand: ((ApplicationCommand) -> Void)?
    var canPerform: ((ApplicationCommand) -> Bool)?

    func install() {
        let menu = NSMenu()

        func submenu(_ title: String) -> NSMenu {
            let item = NSMenuItem()
            let submenu = NSMenu(title: title)
            item.submenu = submenu
            menu.addItem(item)
            return submenu
        }

        func add(_ title: String, _ command: ApplicationCommand, _ key: String = "", to menu: NSMenu)
            -> NSMenuItem
        {
            let item = menu.addItem(
                withTitle: title, action: #selector(performCommand(_:)), keyEquivalent: key)
            item.target = self
            item.representedObject = command
            return item
        }

        let app = submenu("ElseBox")
        _ = add("About ElseBox", .about, to: app)
        app.addItem(.separator())
        _ = add("Configure Virtual Machine…", .configure, ",", to: app)
        app.addItem(.separator())
        app.addItem(
            withTitle: "Quit ElseBox", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu("File")
        _ = add("New Virtual Machine…", .newVM, "n", to: file)
        _ = add("Open .asvm…", .openVM, "o", to: file)
        _ = add("Show VM Library", .showLibrary, "l", to: file)
        _ = add("Import Previous VM…", .importPrevious, to: file)

        let view = submenu("View")
        statusItem = add("Show Status Bar", .toggleStatus, to: view)
        entireDisplayItem = add("Use Entire Display", .toggleEntireDisplay, to: view)
        nativeFullScreenItem = add("Enter Full Screen", .toggleFullScreen, "f", to: view)
        nativeFullScreenItem.keyEquivalentModifierMask = [.control, .command]

        let vm = submenu("Virtual Machine")
        _ = add("Start Virtual Machine", .start, "r", to: vm)
        let headless = add("Start Headless", .startHeadless, "r", to: vm)
        headless.keyEquivalentModifierMask = [.option, .command]
        _ = add("Shut Down", .shutDown, to: vm)
        _ = add("Force Stop…", .forceStop, to: vm)
        vm.addItem(.separator())
        _ = add("Configure…", .configure, to: vm)
        _ = add("Boot from Startup Disk", .bootFromDisk, to: vm)

        let devices = submenu("Devices")
        devicesItem = menu.items.last
        disksItem = NSMenuItem(title: "Disks", action: nil, keyEquivalent: "")
        devices.addItem(disksItem)

        let windows = submenu("Window")
        let minimize = windows.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        minimize.target = nil
        let zoom = windows.addItem(
            withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        zoom.target = nil
        windows.addItem(.separator())
        _ = add("VM Library", .showLibrary, "0", to: windows)
        windows.addItem(.separator())
        let bringAll = windows.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "")
        bringAll.target = nil
        NSApp.windowsMenu = windows
        NSApp.mainMenu = menu
        update(activeSession: nil)
    }

    func update(activeSession: VMSessionController?) {
        statusItem.state = activeSession?.statusBarVisible == true ? .on : .off
        entireDisplayItem.state = activeSession?.entireDisplay == true ? .on : .off
        nativeFullScreenItem.title =
            activeSession?.nativeFullScreen == true ? "Exit Full Screen" : "Enter Full Screen"
        let runningSession = activeSession.flatMap { $0.hasRunningGuest ? $0 : nil }
        devicesItem.isHidden = runningSession == nil
        disksItem.submenu = runningSession?.disksMenu
    }

    @objc private func performCommand(_ item: NSMenuItem) {
        guard let command = item.representedObject as? ApplicationCommand else { return }
        onCommand?(command)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let command = item.representedObject as? ApplicationCommand else { return true }
        return canPerform?(command) ?? false
    }
}
