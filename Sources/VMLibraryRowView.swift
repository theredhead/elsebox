import AppKit

/// A vertically centered OS mark, name, resource summary and state for the library list.
@MainActor
final class VMLibraryRowView: NSView {
    init(bundle: VMBundle, state: String) {
        super.init(frame: .zero)
        let icon = GuestIconView(distribution: bundle.distribution)
        let name = NSTextField(labelWithString: bundle.name)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let specs = NSTextField(
            labelWithString: (try? bundle.resolvedSettings()).map { VMHardwareSummary.text(settings: $0) }
                ?? bundle.preset.title)
        specs.font = .systemFont(ofSize: 12)
        specs.lineBreakMode = .byWordWrapping
        specs.maximumNumberOfLines = 2
        specs.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        specs.textColor = .secondaryLabelColor
        let status = NSTextField(labelWithString: state)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor =
            (state == "Running" ? NSColor.systemGreen : NSColor.tertiaryLabelColor).cgColor
        let statusLine = NSStackView(views: [dot, status])
        statusLine.spacing = 6
        statusLine.alignment = .centerY
        let text = NSStackView(views: [name, specs, statusLine])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4
        for view in [icon, text, dot] { view.translatesAutoresizingMaskIntoConstraints = false }
        addSubview(icon)
        addSubview(text)
        toolTip = bundle.url.path
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 48),
            icon.heightAnchor.constraint(equalToConstant: 48),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.widthAnchor.constraint(equalTo: text.widthAnchor),
            specs.widthAnchor.constraint(equalTo: text.widthAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
