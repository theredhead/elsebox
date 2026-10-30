import AppKit

@MainActor
final class LibraryWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    let window: NSWindow
    private let table = NSTableView()
    private let message = NSTextField(
        labelWithString: "Virtual machines")
    private let start = NSButton(title: "Start", target: nil, action: nil)
    private let configure = NSButton(title: "Configure…", target: nil, action: nil)
    private let show = NSButton(title: "Show Window", target: nil, action: nil)
    private let remove = NSButton(title: "Remove from Library", target: nil, action: nil)
    var machines: [VMBundle] = []
    var state: ((UUID) -> String)?
    var canStart: ((UUID) -> Bool)?
    var canConfigure: ((UUID) -> Bool)?
    var onStart: ((VMBundle) -> Void)?
    var onConfigure: ((VMBundle) -> Void)?
    var onShow: ((VMBundle) -> Void)?
    var onRemove: ((VMBundle) -> Void)?
    var onNew: (() -> Void)?
    var onOpen: (() -> Void)?
    var onActivate: (() -> Void)?
    var onSelection: (() -> Void)?
    var selected: VMBundle? {
        machines.indices.contains(table.selectedRow) ? machines[table.selectedRow] : nil
    }

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "VirtualMac — VM Library"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 760, height: 330)
        window.delegate = self
        let content = window.contentView!
        let new = NSButton(title: "New VM…", target: self, action: #selector(newVM))
        let open = NSButton(title: "Open .asvm…", target: self, action: #selector(openVM))
        let buttons = NSStackView(views: [new, open, start, configure, show, remove])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        for case let button as NSButton in buttons.views { button.bezelStyle = .rounded }
        start.target = self
        start.action = #selector(startVM)
        configure.target = self
        configure.action = #selector(configureVM)
        show.target = self
        show.action = #selector(showVM)
        remove.target = self
        remove.action = #selector(removeVM)
        for (id, title, width) in [
            ("name", "Virtual Machine", 200.0), ("system", "System", 150.0), ("state", "Status", 110.0),
            ("location", "Bundle", 400.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(showVM)
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Virtual machines")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for view in [buttons, scroll, message] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: buttons.bottomAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: message.topAnchor, constant: -12),
            message.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            message.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            message.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.center()
        updateButtons()
    }

    func showWindow() { window.makeKeyAndOrderFront(nil) }
    func setMessage(_ text: String) { message.stringValue = text }
    func reload(_ machines: [VMBundle], select id: UUID? = nil) {
        let selection = id ?? selected?.id
        self.machines = machines
        table.reloadData()
        if let selection, let index = machines.firstIndex(where: { $0.id == selection }) {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        updateButtons()
    }
    private func updateButtons() {
        start.isEnabled = selected.map { canStart?($0.id) ?? true } ?? false
        configure.isEnabled = selected.map { canConfigure?($0.id) ?? true } ?? false
        show.isEnabled = selected != nil
        remove.isEnabled = selected.map { (state?($0.id) ?? "Stopped") == "Stopped" } ?? false
    }
    func numberOfRows(in tableView: NSTableView) -> Int { machines.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard machines.indices.contains(row) else { return nil }
        let machine = machines[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "name": text = machine.name
        case "system": text = machine.distribution.title
        case "state": text = state?(machine.id) ?? "Stopped"
        default: text = machine.url.path
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = text
        let cell = NSTableCellView()
        cell.textField = label
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        onSelection?()
    }
    func windowDidBecomeKey(_ notification: Notification) { onActivate?() }
    @objc private func newVM() { onNew?() }
    @objc private func openVM() { onOpen?() }
    @objc private func startVM() { if let selected { onStart?(selected) } }
    @objc private func configureVM() { if let selected { onConfigure?(selected) } }
    @objc private func showVM() { if let selected { onShow?(selected) } }
    @objc private func removeVM() { if let selected { onRemove?(selected) } }
}
