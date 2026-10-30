import AppKit

/// Maps native close/force-stop dialogs to explicit user intent, keeping button ordering out of session logic.
@MainActor
enum VMCloseConfirmation {
    enum Decision {
        case headless
        case shutDown
        case forceStop
        case cancel
    }

    static func choose(name: String, canShutDown: Bool, canForceStop: Bool) -> Decision {
        let alert = NSAlert()
        alert.messageText = "Close \(name)?"
        alert.informativeText = "Go headless to keep the VM running without its console window."
        alert.addButton(withTitle: "Go Headless")
        var choices: [Decision] = [.headless]
        if canShutDown {
            alert.addButton(withTitle: "Shut Down")
            choices.append(.shutDown)
        }
        if canForceStop {
            alert.addButton(withTitle: "Force Stop…")
            choices.append(.forceStop)
        }
        alert.addButton(withTitle: "Cancel")
        choices.append(.cancel)
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return choices.indices.contains(index) ? choices[index] : .cancel
    }

    static func confirmForceStop(name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Force stop \(name)?"
        alert.informativeText =
            "This turns off the virtual machine immediately. Unsaved guest changes may be lost."
        alert.addButton(withTitle: "Force Stop")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
