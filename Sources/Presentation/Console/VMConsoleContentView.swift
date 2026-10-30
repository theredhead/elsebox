import AppKit

/// Owns the console's viewport, status bar and stopped overlay; it does not start or stop guests.
@MainActor
final class VMConsoleContentView: NSView {
    let vmView = VMInputView()
    let activityView = VMActivityView()
    private let status = NSTextField(labelWithString: "Stopped")
    private let statusBar = NSView()
    private var vmBottomWithStatus: NSLayoutConstraint!
    private var vmBottomWithoutStatus: NSLayoutConstraint!
    private var stoppedOverlay: VMDetailsView!

    var onStart: (() -> Void)?
    var onConfigure: (() -> Void)?

    var statusText: String {
        get { status.stringValue }
        set { status.stringValue = newValue }
    }

    var statusBarVisible: Bool { !statusBar.isHidden }

    init(bundle: VMBundle) {
        super.init(frame: .zero)
        let content = self
        vmView.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(vmView)
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        activityView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusBar)
        statusBar.addSubview(status)
        statusBar.addSubview(activityView)
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        vmBottomWithStatus = vmView.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -4)
        vmBottomWithoutStatus = vmView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            statusBar.heightAnchor.constraint(equalToConstant: 28),
            status.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            status.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            activityView.leadingAnchor.constraint(greaterThanOrEqualTo: status.trailingAnchor, constant: 12),
            activityView.widthAnchor.constraint(equalToConstant: 234),
            activityView.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            activityView.topAnchor.constraint(equalTo: statusBar.topAnchor),
            activityView.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor),
            vmView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            vmView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            vmView.topAnchor.constraint(equalTo: content.topAnchor),
        ])
        setStatusBarVisible((try? bundle.resolvedSettings().showsStatusBar) ?? true)
        stoppedOverlay = VMDetailsView(bundle: bundle)
        stoppedOverlay.onStart = { [weak self] in self?.onStart?() }
        stoppedOverlay.onConfigure = { [weak self] in self?.onConfigure?() }
        stoppedOverlay.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stoppedOverlay)
        NSLayoutConstraint.activate([
            stoppedOverlay.leadingAnchor.constraint(equalTo: vmView.leadingAnchor),
            stoppedOverlay.trailingAnchor.constraint(equalTo: vmView.trailingAnchor),
            stoppedOverlay.topAnchor.constraint(equalTo: vmView.topAnchor),
            stoppedOverlay.bottomAnchor.constraint(equalTo: vmView.bottomAnchor),
        ])
        vmView.capturesSystemKeys = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setStatusBarVisible(_ visible: Bool) {
        statusBar.isHidden = !visible
        NSLayoutConstraint.deactivate([vmBottomWithStatus, vmBottomWithoutStatus])
        (visible ? vmBottomWithStatus : vmBottomWithoutStatus).isActive = true
        layoutSubtreeIfNeeded()
    }

    func updateStoppedOverlay(visible: Bool, canStart: Bool, canConfigure: Bool) {
        stoppedOverlay.isHidden = !visible
        stoppedOverlay.refresh(canStart: canStart, canConfigure: canConfigure)
    }
}
