import AppKit
import Virtualization

@MainActor
final class VMStoppedView: NSView {
    private let bundle: VMBundle
    private let artwork: GuestIconView
    private let preview = NSImageView()
    private let downloadProgress = NSProgressIndicator()
    private var downloading = false
    private let downloadMenuItem = NSMenuItem()
    var onDownloadAction: (() -> Void)?
    private let livePreview = VMDetailPreview()
    private let thumbnails: VMThumbnailController
    private var hasLivePreview = false
    private let summary = NSTextField(labelWithString: "")
    private let displaySummary = NSTextField(labelWithString: "")
    private let stateLabel = NSTextField(labelWithString: "Stopped")
    private let mediaRows = VMDetailRows()
    private let networkRows = VMDetailRows()
    private let powerButton = VMDetailPowerButton()
    private let configureButton = NSButton()
    private let showButton = NSButton()
    private let removeButton = NSButton()
    private var mediaIDs: [String] = []
    private var mediaSignature = ""
    private var addresses: [String] = []
    private var networkSignature = ""
    private var canStart = true
    private var canShutDown = false
    private var canForceStop = false
    var onStart: (() -> Void)?
    var onConfigure: (() -> Void)?
    var onShow: (() -> Void)?
    var onRemove: (() -> Void)? { didSet { removeButton.isHidden = onRemove == nil } }
    var onShutDown: (() -> Void)?
    var onForceStop: (() -> Void)?
    var onEjectMedia: ((String) -> Void)?

    init(bundle: VMBundle) {
        self.bundle = bundle
        thumbnails = VMThumbnailController(bundle: bundle)
        artwork = GuestIconView(distribution: bundle.distribution)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        downloadProgress.style = .bar
        downloadProgress.controlSize = .small
        downloadProgress.minValue = 0
        downloadProgress.maxValue = 1
        downloadProgress.isHidden = true
        downloadProgress.translatesAutoresizingMaskIntoConstraints = false
        let downloadMenu = NSMenu()
        downloadMenuItem.target = self
        downloadMenuItem.action = #selector(downloadAction)
        downloadMenu.addItem(downloadMenuItem)
        downloadProgress.menu = downloadMenu
        addSubview(downloadProgress)
        NSLayoutConstraint.activate([
            downloadProgress.topAnchor.constraint(equalTo: topAnchor),
            downloadProgress.leadingAnchor.constraint(equalTo: leadingAnchor),
            downloadProgress.trailingAnchor.constraint(equalTo: trailingAnchor),
            downloadProgress.heightAnchor.constraint(equalToConstant: 4),
        ])
        powerButton.target = self
        powerButton.action = #selector(power)
        powerButton.toolTip = "Start VM"
        powerButton.setAccessibilityLabel("Start VM")
        configureIcon(
            configureButton, symbol: "gearshape", label: "Configure VM…", action: #selector(configure))
        configureIcon(showButton, symbol: "macwindow", label: "Show VM Window", action: #selector(showWindow))
        configureIcon(removeButton, symbol: "trash", label: "Remove VM…", action: #selector(remove))
        removeButton.isHidden = true
        let powerHost = NSView()
        powerHost.translatesAutoresizingMaskIntoConstraints = false
        powerButton.translatesAutoresizingMaskIntoConstraints = false
        powerHost.addSubview(powerButton)
        addSubview(powerHost)
        NSLayoutConstraint.activate([
            powerHost.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            powerHost.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            powerHost.widthAnchor.constraint(equalToConstant: 44),
            powerHost.heightAnchor.constraint(equalToConstant: 44),
            powerButton.centerXAnchor.constraint(equalTo: powerHost.centerXAnchor),
            powerButton.centerYAnchor.constraint(equalTo: powerHost.centerYAnchor),

        ])
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
        let heading = NSStackView(views: [title, system, summary, displaySummary, stateLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 7
        heading.translatesAutoresizingMaskIntoConstraints = false
        addSubview(heading)
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: powerHost.leadingAnchor, constant: -16),
        ])
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setAccessibilityLabel("Last VM screenshot")
        preview.translatesAutoresizingMaskIntoConstraints = false
        livePreview.translatesAutoresizingMaskIntoConstraints = false
        livePreview.automaticallyReconfiguresDisplay = false
        livePreview.setAccessibilityLabel("Live VM preview")
        livePreview.isHidden = true
        artwork.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            livePreview.widthAnchor.constraint(equalToConstant: 256),
            livePreview.heightAnchor.constraint(equalToConstant: 160),
            preview.widthAnchor.constraint(equalToConstant: 256),
            preview.heightAnchor.constraint(equalToConstant: 160),
            artwork.widthAnchor.constraint(equalToConstant: 88),
            artwork.heightAnchor.constraint(equalToConstant: 88),
        ])
        let actions = NSStackView(views: [showButton, configureButton, removeButton])
        actions.spacing = 12
        let media = makeSection(title: "Removable Media", symbol: "externaldrive", rows: mediaRows)
        let network = makeSection(title: "Network", symbol: "network", rows: networkRows)
        let lists = NSStackView(views: [media, network])
        lists.distribution = .fillEqually
        lists.alignment = .top
        lists.spacing = 16
        let content = NSStackView(views: [livePreview, preview, artwork, actions, lists])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 20
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 24),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            lists.widthAnchor.constraint(equalTo: content.widthAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -20),
        ])
        refresh(canStart: true, canConfigure: true)
        setNetwork(snapshot: nil, live: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureIcon(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.bezelStyle = .rounded
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    private func makeSection(title: String, symbol: String, rows: NSStackView) -> NSView {
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
        return section
    }

    func refresh(
        canStart: Bool, canConfigure: Bool, state: String = "Stopped", canRemove: Bool = false,
        media: [VMRemovableMedium] = []
    ) {
        self.canStart = canStart
        updateMedia(media)
        removeButton.isEnabled = canRemove
        stateLabel.stringValue = state
        stateLabel.isHidden = downloading
        showButton.isEnabled = (state == "Running" || state == "Paused") && onShow != nil
        configureButton.isEnabled = canConfigure
        powerButton.isEnabled = canStart || canShutDown || canForceStop
        let label =
            canStart
            ? "Start VM"
            : (downloading
                ? "Downloads in progress"
                : (canShutDown ? "Shut Down VM" : (canForceStop ? "Force Stop VM…" : "VM not ready")))
        powerButton.toolTip = label
        powerButton.setAccessibilityLabel(label)
        powerButton.setPoweredOn(state == "Running" || state == "Paused")
        guard let settings = try? bundle.resolvedSettings() else { return }
        summary.stringValue = VMHardwareSummary.text(
            settings: settings, diskCapacity: VMDiskStore.logicalCapacity(for: settings))
        preview.image = NSImage(contentsOf: bundle.url.appendingPathComponent("Thumbnail.jpg"))
        preview.isHidden = hasLivePreview || preview.image == nil
        artwork.isHidden = hasLivePreview || preview.image != nil
        displaySummary.stringValue =
            "ARM64 · \(settings.displayWidth ?? 1920) × \(settings.displayHeight ?? 1080)"
    }

    func setDownloadState(_ state: InstallerPreparationState?) {
        downloading = state?.active == true
        let visible = state.map { $0.active || $0.failed } ?? false
        downloadProgress.isHidden = !visible
        guard let state, visible else {
            downloadProgress.stopAnimation(nil)
            return
        }
        downloadProgress.isIndeterminate = state.active && state.fraction == nil
        downloadProgress.doubleValue = state.fraction ?? 0
        if downloadProgress.isIndeterminate {
            downloadProgress.startAnimation(nil)
        } else {
            downloadProgress.stopAnimation(nil)
        }
        let description = state.fraction.map { "\(state.message) \(Int($0 * 100))%" } ?? state.message
        downloadProgress.toolTip = description
        downloadProgress.setAccessibilityLabel(description)
        downloadMenuItem.title = state.active ? "Cancel Download" : "Retry Download"
    }

    @objc private func downloadAction() { onDownloadAction?() }

    func setLivePreview(_ machine: VZVirtualMachine?) {
        hasLivePreview = machine != nil
        if livePreview.virtualMachine !== machine { livePreview.virtualMachine = machine }
        livePreview.isHidden = !hasLivePreview
        thumbnails.update(view: livePreview, running: hasLivePreview)
    }

    func updateStopControls(canShutDown: Bool, canForceStop: Bool) {
        self.canShutDown = canShutDown
        self.canForceStop = canForceStop
    }

    func setNetwork(snapshot: VMNetworkSnapshot?, live: Bool) {
        let signature = "\(live)-\(snapshot?.macAddresses ?? [])-\(snapshot?.addresses ?? [])"
        guard signature != networkSignature else { return }
        networkSignature = signature
        clear(networkRows)
        addresses = snapshot?.addresses ?? []
        if addresses.isEmpty { addRow(to: networkRows, title: "No IP address available") }
        for (index, address) in addresses.enumerated() {
            let button = NSButton()
            configureIcon(
                button, symbol: "doc.on.doc", label: "Copy \(address)", action: #selector(copyAddress(_:)))
            button.tag = index
            addRow(
                to: networkRows, title: address, subtitle: live ? "IP address" : "Last known IP",
                button: button)
        }
        addRow(
            to: networkRows, title: "VirtIO · NAT", subtitle: live ? "Connected" : "Last known configuration")
        for mac in snapshot?.macAddresses ?? [] {
            addRow(to: networkRows, title: mac, subtitle: "MAC address")
        }
    }

    private func updateMedia(_ media: [VMRemovableMedium]) {
        let signature = media.map { "\($0.id)-\($0.name)-\($0.readOnly)-\($0.canEject)-\($0.isInstaller)" }
            .joined(separator: "|")
        guard signature != mediaSignature || mediaRows.arrangedSubviews.isEmpty else { return }
        mediaSignature = signature
        clear(mediaRows)
        mediaIDs = media.map { $0.id }
        if media.isEmpty { addRow(to: mediaRows, title: "None connected") }
        for (index, item) in media.enumerated() {
            let button = NSButton()
            configureIcon(
                button, symbol: "eject", label: "Eject \(item.name)", action: #selector(ejectMedium(_:)))
            button.tag = index
            button.isEnabled = item.canEject
            addRow(
                to: mediaRows, title: item.name,
                subtitle:
                    "\(item.isInstaller ? "Installer · " : "")\(item.readOnly ? "Read only" : "Read/write")",
                button: button)
        }
    }

    private func clear(_ rows: NSStackView) {
        for child in rows.arrangedSubviews {
            rows.removeArrangedSubview(child)
            child.removeFromSuperview()
        }
    }

    private func addRow(to rows: NSStackView, title: String, subtitle: String? = nil, button: NSButton? = nil)
    {
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

    @objc private func power() {
        if canStart {
            onStart?()
        } else if canShutDown {
            onShutDown?()
        } else if canForceStop {
            onForceStop?()
        }
    }
    @objc private func copyAddress(_ sender: NSButton) {
        guard addresses.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addresses[sender.tag], forType: .string)
    }
    @objc private func ejectMedium(_ sender: NSButton) {
        guard mediaIDs.indices.contains(sender.tag) else { return }
        onEjectMedia?(mediaIDs[sender.tag])
    }
    @objc private func showWindow() { onShow?() }
    @objc private func remove() { onRemove?() }
    @objc private func configure() { onConfigure?() }
}

@MainActor
private final class VMDetailRows: NSStackView {
    override var isFlipped: Bool { true }
}
