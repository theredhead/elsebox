import AppKit

@MainActor
final class NewVMOptionsView: NSView {
    private let distribution = NSPopUpButton()
    private let role = NSPopUpButton()
    let name = NSTextField()
    let capacity = NSTextField()
    private let summary = NSTextField(labelWithString: "")
    var preset: VMStarterPreset {
        return VMStarterPreset(
            distribution: GuestDistribution.allCases[distribution.indexOfSelectedItem],
            role: GuestRole.allCases[role.indexOfSelectedItem])
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 450, height: 205))
        distribution.addItems(withTitles: GuestDistribution.allCases.map { $0.title })
        role.addItems(withTitles: GuestRole.allCases.map { $0.title })
        distribution.target = self
        distribution.action = #selector(distributionChanged)
        role.target = self
        role.action = #selector(presetChanged)
        for (title, control, y) in [
            ("System:", distribution as NSControl, 165.0), ("Preset:", role, 125.0),
            ("Name:", name, 85.0), ("Disk (GB):", capacity, 45.0),
        ] {
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: 0, y: y + 3, width: 130, height: 24)
            control.frame = NSRect(x: 140, y: y, width: 300, height: 26)
            control.setAccessibilityLabel(title)
            addSubview(label)
            addSubview(control)
        }
        summary.frame = NSRect(x: 0, y: 3, width: 440, height: 24)
        summary.textColor = .secondaryLabelColor
        addSubview(summary)
        distributionChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func distributionChanged() {
        let system = GuestDistribution.allCases[distribution.indexOfSelectedItem]
        role.isEnabled = system.isLinux
        role.selectItem(at: system.isLinux ? 1 : 2)
        presetChanged()
    }

    @objc private func presetChanged() {
        name.stringValue = preset.title
        capacity.stringValue = String(preset.diskGB)
        summary.stringValue = "ARM64 · \(preset.cpu) CPU cores · \(preset.memoryGiB) GiB RAM"
    }
}
