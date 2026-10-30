import Foundation

/// Keeps current and explicitly last-known guest addresses with the VM bundle.
@MainActor
final class VMNetworkMonitor {
    private let bundleURL: URL
    private var timer: Timer?
    private var generation = 0
    private var macAddresses: [String] = []
    private var current: VMNetworkSnapshot?
    private var lastKnown: VMNetworkSnapshot?
    var didChange: (() -> Void)?
    var snapshot: VMNetworkSnapshot? { timer == nil ? lastKnown : current }
    var isLive: Bool { timer != nil && current != nil }

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
        lastKnown = VMNetworkSnapshot.read(from: bundleURL)
    }

    func start(macAddresses: [String]) {
        stop()
        self.macAddresses = macAddresses
        current = nil
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        Task { await tick() }
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        current = nil
        didChange?()
    }

    private func tick() async {
        let token = generation
        let addresses = await VMNetworkAddressSource.shared.addresses(for: macAddresses)
        guard token == generation, timer != nil else { return }
        guard !addresses.isEmpty else {
            if current != nil {
                current = nil
                didChange?()
            }
            return
        }
        guard addresses != current?.addresses else { return }
        let snapshot = VMNetworkSnapshot(macAddresses: macAddresses, addresses: addresses, observedAt: Date())
        current = snapshot
        lastKnown = snapshot
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: bundleURL.appendingPathComponent("NetworkAddresses.json"), options: .atomic)
        }
        didChange?()
    }
}
