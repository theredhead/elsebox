import AppKit

/// Applies the shared field/label/button layout without owning any preference values or validation.
@MainActor
enum PreferenceForm {
    static func field(_ control: NSControl, label: String, y: CGFloat, in view: NSView) {
        let text = NSTextField(labelWithString: label)
        text.frame = NSRect(x: 20, y: y + 3, width: 175, height: 22)
        control.frame = NSRect(x: 205, y: y, width: 160, height: 26)
        view.addSubview(text)
        view.addSubview(control)
    }

    static func heading(_ title: String, y: CGFloat, in view: NSView) {
        let label = NSTextField(labelWithString: title)
        label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        label.frame = NSRect(x: 20, y: y, width: 500, height: 22)
        view.addSubview(label)
    }

    static func note(_ text: String, x: CGFloat = 20, y: CGFloat, in view: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: y, width: 530 - x, height: 20)
        view.addSubview(label)
    }

    @discardableResult
    static func button(
        _ title: String, action: Selector, target: AnyObject, x: CGFloat, y: CGFloat, in view: NSView
    )
        -> NSButton
    {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.frame = NSRect(x: x, y: y, width: 150, height: 30)
        view.addSubview(button)
        return button
    }
}
