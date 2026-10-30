import CryptoKit
import Foundation

private actor DownloadGate {
    private var started = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var transfer: CheckedContinuation<Void, Never>?
    private var count = 0

    func pause() async {
        count += 1
        started = true
        waiting?.resume()
        waiting = nil
        await withCheckedContinuation { transfer = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        transfer?.resume()
        transfer = nil
    }
    func downloads() -> Int { count }
}

private struct GatedTransport: InstallerTransport {
    let gate: DownloadGate
    let body: Data
    func data(from url: URL) async throws -> Data { throw settingsError("Unexpected metadata request") }
    func download(from url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        progress(0.25)
        await gate.pause()
        try Task.checkCancellation()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: file)
        return file
    }
}

@main
struct PreparationChecks {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Preparation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = InstallerMediaCache(root: root.appendingPathComponent("Media"))
        let body = Data("Windows ARM64 fixture".utf8)
        let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let image = InstallerImage(url: URL(string: "https://example.com/windows.iso")!, sha256: digest)
        let gate = DownloadGate()
        let service = InstallerMediaService(
            transport: GatedTransport(gate: gate, body: body), windowsInstaller: { image })
        let bundle = try VMBundle.create(
            at: root.appendingPathComponent("Test.asvm"), name: "Test", capacityGB: 8,
            preset: VMStarterPreset(distribution: .windows, role: .desktop), mediaCache: cache)
        try InstallerPreparation.begin(bundle: bundle, settings: bundle.resolvedSettings(), service: service)
        await gate.waitUntilStarted()
        precondition(InstallerPreparation.isPreparing(bundle.id))
        precondition(!InstallerPreparation.canStart(bundle: bundle))
        var edited = try bundle.resolvedSettings()
        edited.cpu = 2
        edited.memory = 6 * 1024 * 1024 * 1024
        edited.displayWidth = 1440
        try InstallerPreparation.begin(bundle: bundle, settings: edited, service: service)
        let saved = try bundle.resolvedSettings()
        precondition(saved.cpu == 2)
        // An unrelated ready VM remains startable while this download is blocked.
        let other = try VMBundle.create(
            at: root.appendingPathComponent("Other.asvm"), name: "Other", capacityGB: 8,
            preset: VMStarterPreset(distribution: .windows, role: .desktop), mediaCache: cache)
        var otherSettings = try other.resolvedSettings()
        otherSettings.bootFromInstaller = false
        try other.save(otherSettings)
        precondition(InstallerPreparation.canStart(bundle: other))
        await gate.release()
        let ready = try await InstallerPreparation.save(bundle: bundle, settings: bundle.resolvedSettings())
        precondition(ready.cpu == 2 && ready.memory == edited.memory && ready.displayWidth == 1440)
        precondition(ready.installationMediaPath != nil)
        precondition(InstallerPreparation.canStart(bundle: bundle))
        let count = await gate.downloads()
        precondition(count == 1)

        // Switching the requested installer mid-transfer must not publish the stale result.
        let changedCache = InstallerMediaCache(root: root.appendingPathComponent("Changed Media"))
        let changed = try VMBundle.create(
            at: root.appendingPathComponent("Changed.asvm"), name: "Changed", capacityGB: 8,
            preset: VMStarterPreset(distribution: .windows, role: .desktop), mediaCache: changedCache)
        let secondGate = DownloadGate()
        let secondService = InstallerMediaService(
            transport: GatedTransport(gate: secondGate, body: body), windowsInstaller: { image })
        try InstallerPreparation.begin(
            bundle: changed, settings: changed.resolvedSettings(), service: secondService)
        await secondGate.waitUntilStarted()
        var newRequest = try changed.resolvedSettings()
        newRequest.bootFromInstaller = false
        newRequest.cpu = 3
        try InstallerPreparation.begin(bundle: changed, settings: newRequest, service: secondService)
        await secondGate.release()
        let latest = try await InstallerPreparation.save(
            bundle: changed, settings: changed.resolvedSettings())
        precondition(
            latest.bootFromInstaller == false && latest.installationMediaPath == nil && latest.cpu == 3)
        precondition(InstallerPreparation.canStart(bundle: changed))
        print(
            "Passed: editable settings during transfer, no stale settings/media overwrite, per-VM start gating and transfer reuse"
        )
    }
}
