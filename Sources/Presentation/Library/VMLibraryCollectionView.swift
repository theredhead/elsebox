import AppKit

/// Single-column cards retain native collection selection and the system's scrollbar behavior.
@MainActor
final class VMLibraryCollectionView: NSCollectionView {
    var onEmptyClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if indexPathForItem(at: convert(event.locationInWindow, from: nil)) == nil {
            selectionIndexPaths = []
            window?.makeFirstResponder(self)
            onEmptyClick?()
            return
        }
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDoubleClick?() }
    }

    override func layout() {
        if let flow = collectionViewLayout as? NSCollectionViewFlowLayout {
            let size = NSSize(width: max(1, bounds.width - 16), height: 100)
            if flow.itemSize != size {
                flow.itemSize = size
                flow.invalidateLayout()
            }
        }
        super.layout()
    }
}

/// Adapts a VM row to native collection selection and reuse without owning registry state.
@MainActor
final class VMLibraryCollectionItem: NSCollectionViewItem {
    override var isSelected: Bool { didSet { updateSelection() } }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
    }

    func configure(bundle: VMBundle, state: String) {
        for child in view.subviews { child.removeFromSuperview() }

        let row = VMLibraryRowView(bundle: bundle, state: state)
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            row.topAnchor.constraint(equalTo: view.topAnchor),
            row.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        updateSelection()
    }

    private func updateSelection() {
        guard isViewLoaded else { return }
        view.layer?.backgroundColor =
            (isSelected
            ? NSColor.unemphasizedSelectedContentBackgroundColor : NSColor.clear).cgColor
    }
}
