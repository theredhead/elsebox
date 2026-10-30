import AppKit

/// Presents identity, specifications and state together, leaving power/boot decisions to the details controller.
@MainActor
final class VMDetailsHeader: NSStackView {
    private let summary = NSTextField(labelWithString: "")
    private let displaySummary = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "Stopped")

    init(bundle: VMBundle) {
        super.init(frame: .zero)
        let title = NSTextField(labelWithString: bundle.name)
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let system = NSTextField(labelWithString: bundle.preset.title)
        system.textColor = .secondaryLabelColor
        system.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: 14)
        displaySummary.textColor = .secondaryLabelColor
        stateLabel.textColor = .secondaryLabelColor
        for view in [title, system, summary, displaySummary, stateLabel] { addArrangedSubview(view) }
        orientation = .vertical
        alignment = .leading
        spacing = 7
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(settings: VMSettings, state: String, downloading: Bool) {
        stateLabel.stringValue = state
        stateLabel.isHidden = downloading
        summary.stringValue = VMHardwareSummary.text(
            settings: settings, diskCapacity: VMDiskStore.logicalCapacity(for: settings))
        displaySummary.stringValue =
            "ARM64 · \(settings.displayWidth ?? 1920) × \(settings.displayHeight ?? 1080)"
    }
}
