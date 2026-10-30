import AppKit

/// Builds the unified sidebar/detail geometry without owning selection, VM actions or collection data.
@MainActor
enum LibraryWindowLayout {
    static func make(
        collection: VMLibraryCollectionView, split: NSSplitViewController, detailHost: NSView,
        message: NSTextField, overview: VMLibraryOverviewView
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "ElseBox — VM Library"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 980, height: 680)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        let sidebar = NSViewController()
        sidebar.view = NSView()
        let flow = NSCollectionViewFlowLayout()
        flow.itemSize = NSSize(width: 304, height: 100)
        flow.minimumLineSpacing = 4
        flow.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        collection.collectionViewLayout = flow
        collection.autoresizingMask = [.width]
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsEmptySelection = true
        collection.allowsMultipleSelection = false
        collection.register(
            VMLibraryCollectionItem.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("VMCard"))
        collection.setAccessibilityLabel("Virtual machines")
        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebar.view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: sidebar.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sidebar.view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: sidebar.view.bottomAnchor),
        ])
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.allowsFullHeightLayout = true
        sidebarItem.titlebarSeparatorStyle = .none
        sidebarItem.minimumThickness = 320
        sidebarItem.maximumThickness = 440
        sidebarItem.preferredThicknessFraction = 0.34
        let main = NSViewController()
        main.view = NSView()
        for view in [detailHost, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            main.view.addSubview(view)
        }
        overview.translatesAutoresizingMaskIntoConstraints = false
        detailHost.addSubview(overview)
        NSLayoutConstraint.activate([
            detailHost.leadingAnchor.constraint(equalTo: main.view.leadingAnchor),
            detailHost.trailingAnchor.constraint(equalTo: main.view.trailingAnchor),
            detailHost.topAnchor.constraint(equalTo: main.view.safeAreaLayoutGuide.topAnchor),
            detailHost.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -12),
            message.leadingAnchor.constraint(equalTo: main.view.leadingAnchor, constant: 20),
            message.trailingAnchor.constraint(equalTo: main.view.trailingAnchor, constant: -20),
            message.bottomAnchor.constraint(equalTo: main.view.bottomAnchor, constant: -12),
            overview.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor),
            overview.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor),
            overview.topAnchor.constraint(equalTo: detailHost.topAnchor),
            overview.bottomAnchor.constraint(equalTo: detailHost.bottomAnchor),
        ])
        message.textColor = .secondaryLabelColor
        let detailItem = NSSplitViewItem(viewController: main)
        detailItem.minimumThickness = 600
        detailItem.titlebarSeparatorStyle = .none
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        window.contentViewController = split
        return window
    }
}
