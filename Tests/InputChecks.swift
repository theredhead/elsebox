import AppKit

@main @MainActor
struct InputChecks {
    static func main() {
        for type: NSEvent.EventType in [.rightMouseDown, .rightMouseDragged, .rightMouseUp] {
            let original = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 48, y: 72),
                modifierFlags: [.shift, .option], timestamp: 123,
                windowNumber: 0, context: nil, eventNumber: 1,
                clickCount: 2, pressure: 0.5)!
            let quartz = original.cgEvent!.copy()!
            // Exercise a secondary event with a non-mouse subtype and inconsistent button field.
            quartz.setIntegerValueField(
                .mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
            quartz.setIntegerValueField(.mouseEventButtonNumber, value: 0)
            let input = NSEvent(cgEvent: quartz)!
            let output = VMInputView.usbSecondaryClick(from: input)
            precondition(output.type == type && output.buttonNumber == 1)
            precondition(output.cgEvent!.getIntegerValueField(.mouseEventSubtype) == 0)
            precondition(output.cgEvent!.location == input.cgEvent!.location)
            precondition(output.modifierFlags == input.modifierFlags)
            precondition(output.timestamp == input.timestamp && output.clickCount == input.clickCount)
            precondition(output.windowNumber == input.windowNumber)
        }
        let windowEvent = NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 28, y: 32),
            modifierFlags: [], timestamp: 5, windowNumber: 123,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        let normalizedWindowEvent = VMInputView.usbSecondaryClick(from: windowEvent)
        precondition(normalizedWindowEvent.windowNumber == windowEvent.windowNumber)
        precondition(normalizedWindowEvent.locationInWindow == windowEvent.locationInWindow)
        let left = NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        precondition(VMInputView.usbSecondaryClick(from: left) === left)
        print(
            "Passed: secondary down/drag/up normalization, position/modifiers/timing preservation, primary-click passthrough"
        )
    }
}
