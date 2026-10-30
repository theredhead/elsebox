import AppKit

/// Owns observed address rows and explicit copy actions, independent of the details layout and network probing.
@MainActor
final class VMNetworkInfoList: NSObject {
    private let list = VMDetailList(title: "Network", symbol: "network")

    var view: NSView { list.view }

    private var networkSignature = ""
    private var addresses: [String] = []

    func update(snapshot: VMNetworkSnapshot?, live: Bool) {
        let signature = "\(live)-\(snapshot?.macAddresses ?? [])-\(snapshot?.addresses ?? [])"
        guard signature != networkSignature else { return }
        networkSignature = signature
        list.clear()
        addresses = snapshot?.addresses ?? []
        if addresses.isEmpty { list.addRow(title: "No IP address available") }
        for (index, address) in addresses.enumerated() {
            let button = VMDetailList.actionButton(
                symbol: "doc.on.doc", label: "Copy \(address)", target: self,
                action: #selector(copyAddress(_:)))
            button.tag = index
            list.addRow(
                title: address, subtitle: live ? "IP address" : "Last known IP",
                button: button)
        }
        list.addRow(
            title: "VirtIO · NAT", subtitle: live ? "Connected" : "Last known configuration")
        for mac in snapshot?.macAddresses ?? [] {
            list.addRow(title: mac, subtitle: "MAC address")
        }
    }

    @objc private func copyAddress(_ sender: NSButton) {
        guard addresses.indices.contains(sender.tag) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addresses[sender.tag], forType: .string)
    }
}
