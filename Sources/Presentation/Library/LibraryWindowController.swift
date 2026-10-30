import AppKit
import Virtualization

/// Owns library selection and detail/overview presentation; VM execution and app commands are supplied by callbacks.
@MainActor
final class LibraryWindowController: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate,
    NSWindowDelegate, NSToolbarDelegate
{
    let window: NSWindow
    private let collection = VMLibraryCollectionView()
    private let itemIdentifier = NSUserInterfaceItemIdentifier("VMCard")
    private let split = NSSplitViewController()
    private let detailHost = NSView()
    private let message = NSTextField(labelWithString: "VM Library")
    private var detail: VMDetailsView?
    private var detailURL: URL?
    private let overview = VMLibraryOverviewView(frame: .zero)

    var mediaCleanupRestriction: ((URL) -> String?)? {
        didSet { overview.mediaCleanupRestriction = mediaCleanupRestriction }
    }

    var mediaURL = InstallerMediaCache.shared.root

    var overviewActivity: (() -> VMLibraryActivityInput)? {
        didSet { overview.activityInput = overviewActivity }
    }

    private var reloading = false
    private let newItem = NSToolbarItem.Identifier("NewVM")
    var machines: [VMBundle] = []
    var state: ((UUID) -> String)?
    var canShutDown: ((UUID) -> Bool)?
    var canForceStop: ((UUID) -> Bool)?
    var onShutDown: ((VMBundle) -> Void)?
    var onForceStop: ((VMBundle) -> Void)?
    var canStart: ((UUID) -> Bool)?
    var canRemove: ((UUID) -> Bool)?
    var canConfigure: ((UUID) -> Bool)?
    var networkInfo: ((UUID) -> (VMNetworkSnapshot?, Bool))?
    var removableMedia: ((UUID) -> [VMRemovableMedium])?
    var onEjectMedia: ((VMBundle, String) -> Void)?
    var previewMachine: ((UUID) -> VZVirtualMachine?)?
    var downloadState: ((UUID) -> InstallerPreparationState?)?
    var onDownloadAction: ((VMBundle) -> Void)?
    var onStart: ((VMBundle) -> Void)?
    var onConfigure: ((VMBundle) -> Void)?
    var onShow: ((VMBundle) -> Void)?
    var onRemove: ((VMBundle) -> Void)?
    var onNew: (() -> Void)?
    var onActivate: (() -> Void)?
    var onSelection: (() -> Void)?

    var selected: VMBundle? {
        guard let index = collection.selectionIndexPaths.first?.item, machines.indices.contains(index) else {
            return nil
        }
        return machines[index]
    }

    override init() {
        window = LibraryWindowLayout.make(
            collection: collection, split: split, detailHost: detailHost,
            message: message, overview: overview)
        super.init()
        window.delegate = self
        collection.dataSource = self
        collection.delegate = self
        collection.onEmptyClick = { [weak self] in
            self?.updateDetail()
            self?.onSelection?()
        }
        collection.onDoubleClick = { [weak self] in self?.showVM() }

        let toolbar = NSToolbar(identifier: "LibraryToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
        updateDetail()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, newItem, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, newItem, .flexibleSpace]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if id == .toggleSidebar {
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Toggle Sidebar"
            item.toolTip = "Show or hide the VM sidebar"
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.target = split
            item.action = #selector(NSSplitViewController.toggleSidebar(_:))
            item.isNavigational = true
            item.isBordered = false
            return item
        }
        if id == .sidebarTrackingSeparator {
            return NSTrackingSeparatorToolbarItem(identifier: id, splitView: split.splitView, dividerIndex: 0)
        }
        guard id == newItem else { return nil }

        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "Create VM"
        let button = NSButton(
            title: "Create VM", image: NSImage(systemSymbolName: "plus", accessibilityDescription: nil)!,
            target: self, action: #selector(newVM))
        button.imagePosition = .imageOnly
        button.toolTip = "Create VM"
        button.setAccessibilityLabel("Create VM")
        button.bezelStyle = .texturedRounded
        item.view = button
        return item
    }

    func showWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setMessage(_ text: String) { message.stringValue = text }

    func reload(_ machines: [VMBundle], select id: UUID? = nil) {
        let selection = id ?? selected?.id
        reloading = true
        self.machines = machines
        collection.reloadData()
        if let index = machines.firstIndex(where: { $0.id == selection }) {
            collection.selectionIndexPaths = [IndexPath(item: index, section: 0)]
        } else {
            collection.selectionIndexPaths = []
        }
        reloading = false
        overview.updateStorage(vmURLs: machines.map { $0.url }, mediaURL: mediaURL)
        updateDetail()
    }

    func refreshDetails() { updateDetail() }

    private func updateDetail() {
        guard let selected else {
            detail?.removeFromSuperview()
            detail = nil
            detailURL = nil
            overview.isHidden = false
            return
        }
        overview.isHidden = true
        if detailURL != selected.url {
            detail?.removeFromSuperview()
            let view = VMDetailsView(bundle: selected)
            view.onStart = { [weak self] in self?.onStart?(selected) }
            view.onDownloadAction = { [weak self] in self?.onDownloadAction?(selected) }
            view.onShutDown = { [weak self] in self?.onShutDown?(selected) }
            view.onForceStop = { [weak self] in self?.onForceStop?(selected) }
            view.onConfigure = { [weak self] in self?.onConfigure?(selected) }
            view.onShow = { [weak self] in self?.onShow?(selected) }
            view.onRemove = { [weak self] in self?.onRemove?(selected) }
            view.onEjectMedia = { [weak self] in self?.onEjectMedia?(selected, $0) }
            view.translatesAutoresizingMaskIntoConstraints = false
            detailHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: detailHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: detailHost.bottomAnchor),
            ])
            detail = view
            detailURL = selected.url
        }
        detail?.setDownloadState(downloadState?(selected.id))
        detail?.setLivePreview(
            window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
                ? previewMachine?(selected.id) : nil)
        detail?.updateStopControls(
            canShutDown: canShutDown?(selected.id) == true,
            canForceStop: canForceStop?(selected.id) == true)
        let network = networkInfo?(selected.id) ?? (nil, false)
        detail?.setNetwork(snapshot: network.0, live: network.1)
        detail?.refresh(
            canStart: canStart?(selected.id) ?? true,
            canConfigure: canConfigure?(selected.id) ?? true, state: state?(selected.id) ?? "Stopped",
            canRemove: canRemove?(selected.id) ?? (canStart?(selected.id) ?? true),
            media: removableMedia?(selected.id) ?? [])
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        machines.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath)
        -> NSCollectionViewItem
    {
        let item = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath)
        if let card = item as? VMLibraryCollectionItem, machines.indices.contains(indexPath.item) {
            let machine = machines[indexPath.item]
            card.configure(bundle: machine, state: state?(machine.id) ?? "Stopped")
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged()
    }

    private func selectionChanged() {
        guard !reloading else { return }
        updateDetail()
        onSelection?()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        onActivate?()
        updateDetail()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { updateDetail() }

    func windowWillClose(_ notification: Notification) { detail?.setLivePreview(nil) }

    @objc private func newVM() { onNew?() }
    @objc private func showVM() {
        if let selected, state?(selected.id) == "Running" { onShow?(selected) }
    }
}
