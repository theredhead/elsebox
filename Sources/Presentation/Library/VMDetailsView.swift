import AppKit
import Virtualization

/// Composes the selected VM's header, preview, actions and device lists without owning guest execution.
@MainActor
final class VMDetailsView: NSView {
    private let bundle: VMBundle
    private let artwork: GuestIconView
    private let preview = NSImageView()
    private let downloadProgress = VMDownloadProgressView()
    private var downloading = false

    var onDownloadAction: (() -> Void)? { didSet { downloadProgress.onAction = onDownloadAction } }

    private let livePreview = VMDetailPreview()
    private let thumbnails: VMThumbnailController
    private var hasLivePreview = false
    private let header: VMDetailsHeader
    private let media = VMRemovableMediaList()
    private let network = VMNetworkInfoList()
    private let powerButton = VMDetailPowerButton()
    private let configureButton = NSButton()
    private let showButton = NSButton()
    private let removeButton = NSButton()
    private var canStart = true
    private var canShutDown = false
    private var canForceStop = false
    var onStart: (() -> Void)?
    var onConfigure: (() -> Void)?
    var onShow: (() -> Void)?

    var onRemove: (() -> Void)? { didSet { removeButton.isHidden = onRemove == nil } }

    var onShutDown: (() -> Void)?
    var onForceStop: (() -> Void)?

    var onEjectMedia: ((String) -> Void)? {
        get { media.onEjectMedia }
        set { media.onEjectMedia = newValue }
    }

    init(bundle: VMBundle) {
        self.bundle = bundle
        header = VMDetailsHeader(bundle: bundle)
        thumbnails = VMThumbnailController(bundle: bundle)
        artwork = GuestIconView(distribution: bundle.distribution)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        downloadProgress.translatesAutoresizingMaskIntoConstraints = false
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
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 28),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(lessThanOrEqualTo: powerHost.leadingAnchor, constant: -16),
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
        let lists = NSStackView(views: [media.view, network.view])
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
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 24),
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

    func refresh(
        canStart: Bool, canConfigure: Bool, state: String = "Stopped", canRemove: Bool = false,
        media: [VMRemovableMedium] = []
    ) {
        self.canStart = canStart
        self.media.update(media)
        removeButton.isEnabled = canRemove
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
        header.update(settings: settings, state: state, downloading: downloading)
        preview.image = NSImage(contentsOf: bundle.url.appendingPathComponent("Thumbnail.jpg"))
        preview.isHidden = hasLivePreview || preview.image == nil
        artwork.isHidden = hasLivePreview || preview.image != nil
    }

    func setDownloadState(_ state: InstallerPreparationState?) {
        downloading = state?.active == true
        downloadProgress.update(state)
    }

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
        network.update(snapshot: snapshot, live: live)
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

    @objc private func showWindow() { onShow?() }
    @objc private func remove() { onRemove?() }
    @objc private func configure() { onConfigure?() }
}
