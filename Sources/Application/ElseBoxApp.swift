import AppKit

@main
@MainActor
struct ElseBoxApp {
    static func main() {
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.setActivationPolicy(.regular)
        withExtendedLifetime(controller) { application.run() }
    }
}
