import AppKit

/// Owns consistent section/row geometry and vertical alignment, without knowing what a row means.
@MainActor
final class VMDetailList {
    let view: NSView
    private let rows = VMDetailListRows()

    var isEmpty: Bool { rows.arrangedSubviews.isEmpty }

    init(title: String, symbol: String) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        let heading = NSStackView(views: [icon, label])
        heading.spacing = 7
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 0
        rows.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.documentView = rows
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let preferredHeight = scroll.heightAnchor.constraint(equalToConstant: 208)
        preferredHeight.priority = .defaultLow
        preferredHeight.isActive = true
        let section = NSStackView(views: [heading, scroll])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 10
        section.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        section.wantsLayer = true
        section.layer?.cornerRadius = 10
        section.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: section.widthAnchor, constant: -28),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 104),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        view = section
    }

    func clear() {
        for child in rows.arrangedSubviews {
            rows.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
    }

    func addRow(title: String, subtitle: String? = nil, button: NSButton? = nil) {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12)
        name.isSelectable = true
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        name.toolTip = title
        let text = NSStackView(views: [name])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        if let subtitle {
            let detail = NSTextField(labelWithString: subtitle)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            text.addArrangedSubview(detail)
        }

        let row = NSView()
        text.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)
        rows.addArrangedSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalTo: rows.widthAnchor),
            row.heightAnchor.constraint(equalToConstant: 52),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        if let button {
            row.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                text.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -8),
            ])
        } else {
            text.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor).isActive = true
        }
    }

    static func actionButton(symbol: String, label: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: target,
            action: action)
        button.bezelStyle = .rounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }
}

/// Keeps short document lists pinned to the top of their native scroll view.
@MainActor
private final class VMDetailListRows: NSStackView {
    override var isFlipped: Bool { true }
}
