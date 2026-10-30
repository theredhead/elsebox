import AppKit

/// Individual shared-cache cleanup never changes a VM's configuration or boot media references.
@MainActor
final class InstallerMediaPopoverController: NSViewController {
    private let root: URL
    private let restriction: (URL) -> String?
    private let changed: () -> Void
    private let rows = NSStackView()
    private var entries: [CachedInstallerFile] = []

    init(root: URL, restriction: @escaping (URL) -> String?, changed: @escaping () -> Void) {
        self.root = root
        self.restriction = restriction
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 460, height: 360)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        let title = NSTextField(labelWithString: "Shared Install Media")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 14
        scroll.documentView = rows
        for child in [title, scroll] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 18),
            scroll.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18),
            rows.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rows.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            rows.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        reload()
    }

    private func reload() {
        for row in rows.arrangedSubviews {
            rows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        do {
            entries = try InstallerMediaInventory.files(
                in: root, excludingDigests: [BundledGuestTools.audioImageDigest])
            if entries.isEmpty {
                rows.addArrangedSubview(NSTextField(labelWithString: "No cached install media"))
            }
            for (index, entry) in entries.enumerated() {
                let title = NSTextField(labelWithString: title(for: entry))
                title.font = .systemFont(ofSize: 13, weight: .medium)
                let reason = cleanupRestriction(entry)
                let size = ByteCountFormatter.string(fromByteCount: entry.allocatedBytes, countStyle: .file)
                let subtitle = NSTextField(labelWithString: reason.map { "\(size) · \($0)" } ?? size)
                subtitle.font = .systemFont(ofSize: 11)
                subtitle.textColor = .secondaryLabelColor
                let labels = NSStackView(views: [title, subtitle])
                labels.orientation = .vertical
                labels.alignment = .leading
                labels.spacing = 3
                title.lineBreakMode = .byTruncatingMiddle
                subtitle.lineBreakMode = .byTruncatingTail
                let remove = NSButton(
                    image: NSImage(
                        systemSymbolName: "trash", accessibilityDescription: "Move media to Trash")!,
                    target: self, action: #selector(removeMedia(_:)))
                remove.tag = index
                remove.bezelStyle = .rounded
                remove.isEnabled = reason == nil
                remove.toolTip = reason ?? "Move to Trash"
                if reason != nil {
                    remove.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: reason)
                }

                let row = InstallerMediaRowView(labels: labels, button: remove)
                row.toolTip = entry.relativePath
                rows.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
            }
        } catch { rows.addArrangedSubview(NSTextField(labelWithString: error.localizedDescription)) }
    }

    private func downloadableMedia() -> Set<URL> {
        let cache = InstallerMediaCache(root: root)
        var urls: Set<URL> = []
        for distribution in GuestDistribution.allCases where distribution.hasAutomaticInstaller {
            for role in GuestRole.allCases {
                if let url = cache.cached(
                    for: InstallerMediaCache.key(
                        for:
                            VMStarterPreset(distribution: distribution, role: role)))
                {
                    urls.insert(url)
                }
            }
        }
        for culture in WindowsCulture.allCases {
            if let url = cache.cached(for: culture.cacheKey) { urls.insert(url) }
        }

        let driver = cache.file(digest: InstallerMediaService.windowsDriverImage.sha256, extension: "iso")
        urls.insert(driver)
        return Set(urls.map { $0.standardizedFileURL.resolvingSymlinksInPath() })
    }

    private func cleanupRestriction(_ entry: CachedInstallerFile) -> String? {
        if let reason = restriction(entry.url) { return reason }
        return InstallerMediaInventory.canRecreate(entry, root: root, downloadable: downloadableMedia())
            ? nil : "No automatic download source"
    }

    private func title(for entry: CachedInstallerFile) -> String {
        let cache = InstallerMediaCache(root: root)
        if entry.relativePath.hasPrefix("Windows Bootstrap/") { return "Windows boot media" }
        if entry.url.pathExtension == "ipsw" { return "macOS restore image" }
        if entry.url.deletingLastPathComponent().lastPathComponent
            == InstallerMediaService.windowsDriverImage.sha256
        {
            return "Windows VirtIO drivers"
        }
        for culture in WindowsCulture.allCases where cache.cached(for: culture.cacheKey) == entry.url {
            return "Windows · \(culture.title)"
        }
        for distribution in GuestDistribution.allCases where distribution.isLinux {
            for role in GuestRole.allCases {
                let preset = VMStarterPreset(distribution: distribution, role: role)
                if cache.cached(for: InstallerMediaCache.key(for: preset)) == entry.url {
                    return preset.title
                }
            }
        }
        if let volume = InstallerMediaInventory.volumeName(entry.url), !volume.isEmpty {
            if volume == "VMAUDIO" { return "ElseBox audio drivers" }
            if volume.hasPrefix("virtio-win-") { return "Windows VirtIO drivers · \(volume.dropFirst(11))" }
            return volume
        }
        return
            "\(entry.url.lastPathComponent) · \(entry.url.deletingLastPathComponent().lastPathComponent.prefix(12))"
    }

    @objc private func removeMedia(_ sender: NSButton) {
        guard entries.indices.contains(sender.tag) else { return }

        let entry = entries[sender.tag]
        guard InstallerMediaInventory.isMedia(entry.url, inside: root), cleanupRestriction(entry) == nil
        else {
            reload()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Move this install media to Trash?"
        alert.informativeText = title(for: entry)
        alert.addButton(withTitle: "Move to Trash")
        alert.buttons[0].hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            guard cleanupRestriction(entry) == nil else {
                reload()
                return
            }
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            changed()
            reload()
        } catch { NSAlert(error: error).runModal() }
    }
}

/// Fixed row geometry keeps actions in one trailing column; native tracking supplies hover feedback.
@MainActor
private final class InstallerMediaRowView: NSView {
    private var tracking: NSTrackingArea?
    private var hovered = false

    init(labels: NSStackView, button: NSButton) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        for label in labels.arrangedSubviews {
            label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        }
        for child in [labels, button] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 52),
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor =
            (hovered ? NSColor.labelColor.withAlphaComponent(0.06) : NSColor.clear).cgColor
    }
}
