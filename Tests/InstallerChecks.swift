import CryptoKit
import Foundation

private actor TransferCount {
    var downloads = 0
    func increment() { downloads += 1 }
    func value() -> Int { return downloads }
}

private struct FixtureTransport: InstallerTransport {
    let metadata: [String: Data]
    let body: Data
    let counter: TransferCount
    var delay: UInt64 = 0

    func data(from url: URL) async throws -> Data {
        guard let data = metadata[url.absoluteString] else {
            throw settingsError("Unexpected metadata URL: \(url)")
        }
        return data
    }

    func download(from url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        await counter.increment()
        progress(0)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        try Task.checkCancellation()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try body.write(to: file)
        progress(1)
        return file
    }
}

@main
struct InstallerChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "InstallerChecks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data("tiny ARM64 ISO fixture".utf8)
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let base = "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/"
        let manifest = "\(hash) *debian-99.1-arm64-netinst.iso\n\(hash) *debian-99.1-amd64-netinst.iso\n"
        let count = TransferCount()
        let transport = FixtureTransport(
            metadata: [base + "SHA256SUMS": Data(manifest.utf8)], body: body, counter: count,
            delay: 20_000_000)
        let cache = InstallerMediaCache(root: root.appendingPathComponent("Shared Media"))
        let preset = VMStarterPreset(distribution: .debian, role: .minimal)
        let one = try VMBundle.create(
            at: root.appendingPathComponent("One.asvm"), name: "One", capacityGB: 16, preset: preset,
            mediaCache: cache)
        let two = try VMBundle.create(
            at: root.appendingPathComponent("Two.asvm"), name: "Two", capacityGB: 16, preset: preset,
            mediaCache: cache)
        async let first = InstallerMediaService(transport: transport).prepare(
            bundle: one, settings: one.resolvedSettings()
        ) { _, _ in }
        async let second = InstallerMediaService(transport: transport).prepare(
            bundle: two, settings: two.resolvedSettings()
        ) { _, _ in }
        let (readyOne, readyTwo) = try await (first, second)
        precondition(readyOne.installationMediaPath == readyTwo.installationMediaPath)
        let downloads = await count.value()
        precondition(downloads == 1)
        try one.save(readyOne)
        try two.save(readyTwo)
        let storedOne = try one.storedSettings().installationMediaPath!
        let storedTwo = try two.storedSettings().installationMediaPath!
        precondition(storedOne.hasPrefix("media://") && storedOne == storedTwo)
        let savedFile = try cache.resolve(storedOne)
        precondition(tryValue { try Data(contentsOf: savedFile) } == body)
        precondition(!one.contains(savedFile) && !two.contains(savedFile))
        let reopened = try VMBundle.open(one.url, mediaCache: cache)
        precondition(tryValue { try reopened.resolvedSettings().installationMediaPath } == savedFile.path)
        // Offline cache reuse does not need another metadata fetch or download.
        let offline = FixtureTransport(metadata: [:], body: Data(), counter: TransferCount())
        let cached = try await InstallerMediaService(transport: offline).prepare(
            bundle: two, settings: Resources(cpu: 2, memory: 2_147_483_648)
        ) { _, _ in }
        precondition(cached.installationMediaPath == savedFile.path)
        let windows = try VMBundle.create(
            at: root.appendingPathComponent("Windows.asvm"), name: "Windows", capacityGB: 64,
            preset: VMStarterPreset(distribution: .windows, role: .desktop), mediaCache: cache)
        var windowsDiskSettings = try windows.resolvedSettings()
        windowsDiskSettings.bootFromInstaller = true
        windowsDiskSettings.installationMediaPath = savedFile.path
        let windowsSettings = windowsDiskSettings
        precondition(windowsSettings.automaticWindowsDrivers == true)
        let driverCount = TransferCount()
        let driverTransport = FixtureTransport(
            metadata: [:], body: Data("driver fixture".utf8), counter: driverCount)
        async let driverOne = InstallerMediaService(transport: driverTransport).prepare(
            bundle: windows, settings: windowsSettings
        ) { _, _ in }
        async let driverTwo = InstallerMediaService(transport: driverTransport).prepare(
            bundle: windows, settings: windowsSettings
        ) { _, _ in }
        let (driversOne, driversTwo) = try await (driverOne, driverTwo)
        precondition(driversOne.driverMediaPath == nil && driversTwo.driverMediaPath == nil)
        let driverDownloads = await driverCount.value()
        precondition(driverDownloads == 0)
        var legacyDriverSettings = windowsSettings
        legacyDriverSettings.driverMediaPath = root.appendingPathComponent("old-driver.iso").path
        let migrated = try await InstallerMediaService(transport: offline).prepare(
            bundle: windows, settings: legacyDriverSettings
        ) { _, _ in }
        precondition(migrated.driverMediaPath == nil)
        var custom = legacyDriverSettings
        custom.automaticWindowsDrivers = false
        let preserved = try await InstallerMediaService(transport: offline).prepare(
            bundle: windows, settings: custom
        ) { _, _ in }
        precondition(preserved.driverMediaPath == custom.driverMediaPath)
        print(
            "Passed: bundled Windows drivers require zero downloads, release legacy ISOs, preserve custom driver opt-out"
        )
        let installerDownloads = TransferCount()
        let resolverCalls = TransferCount()
        let windowsBody = Data("Windows ARM installer fixture".utf8)
        let windowsHash = SHA256.hash(data: windowsBody).map { String(format: "%02x", $0) }.joined()
        let windowsTransport = FixtureTransport(metadata: [:], body: windowsBody, counter: installerDownloads)
        let windowsImage = InstallerImage(
            url: URL(string: "https://software.download.prss.microsoft.com/Win11_English_Arm64.iso")!,
            sha256: windowsHash)
        var automaticSettings = windowsSettings
        automaticSettings.bootFromInstaller = true
        automaticSettings.installationMediaPath = nil
        automaticSettings.automaticWindowsDrivers = false
        let automaticSnapshot = automaticSettings
        async let windowsOne = InstallerMediaService(
            transport: windowsTransport,
            windowsInstaller: {
                await resolverCalls.increment()
                return windowsImage
            }
        ).prepare(bundle: windows, settings: automaticSnapshot) { _, _ in }
        async let windowsTwo = InstallerMediaService(
            transport: windowsTransport,
            windowsInstaller: {
                await resolverCalls.increment()
                return windowsImage
            }
        ).prepare(bundle: windows, settings: automaticSnapshot) { _, _ in }
        let (windowsReadyOne, windowsReadyTwo) = try await (windowsOne, windowsTwo)
        precondition(windowsReadyOne.installationMediaPath == windowsReadyTwo.installationMediaPath)
        let resolvedCount = await resolverCalls.value()
        precondition(resolvedCount == 1)
        let downloadedWindows = await installerDownloads.value()
        precondition(downloadedWindows == 1)
        let offlineWindows = try await InstallerMediaService(
            transport: offline,
            windowsInstaller: {
                throw settingsError("Cached installer must not contact Microsoft")
            }
        ).prepare(bundle: windows, settings: automaticSnapshot) { _, _ in }
        precondition(offlineWindows.installationMediaPath == windowsReadyOne.installationMediaPath)
        let validatedImage = try WindowsInstallerResolver.image(
            url: windowsImage.url.absoluteString, checksum: hash)
        precondition(validatedImage.sha256 == hash)
        do {
            _ = try WindowsInstallerResolver.image(
                url: "https://example.org/Win11_Arm64.iso", checksum: hash)
            fatalError("Non-Microsoft installer must be rejected")
        } catch {}
        print(
            "Passed: automatic Windows installer resolution, concurrent/offline reuse, Microsoft URL validation"
        )
        let badCache = InstallerMediaCache(root: root.appendingPathComponent("Bad Media"))
        let bad = try VMBundle.create(
            at: root.appendingPathComponent("Bad.asvm"), name: "Bad", capacityGB: 16, preset: preset,
            mediaCache: badCache)
        let original = try Data(contentsOf: bad.settingsURL)
        let corrupt = FixtureTransport(
            metadata: [base + "SHA256SUMS": Data(manifest.utf8)], body: Data("corrupt".utf8),
            counter: TransferCount())
        do {
            _ = try await InstallerMediaService(transport: corrupt).prepare(
                bundle: bad, settings: bad.resolvedSettings()
            ) { _, _ in }
            fatalError("Corrupt installer must not be published")
        } catch {}
        precondition(tryValue { try Data(contentsOf: bad.settingsURL) } == original)
        precondition(
            !FileManager.default.fileExists(atPath: badCache.file(digest: hash, extension: "iso").path))
        let slow = FixtureTransport(
            metadata: [base + "SHA256SUMS": Data(manifest.utf8)], body: body, counter: TransferCount(),
            delay: 5_000_000_000)
        let cancelled = Task {
            try await InstallerMediaService(transport: slow).prepare(
                bundle: bad, settings: bad.resolvedSettings()
            ) { _, _ in }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            fatalError("Download should cancel")
        } catch is CancellationError {}
        precondition(tryValue { try Data(contentsOf: bad.settingsURL) } == original)
        try checkCatalogs(hash: hash)
        print(
            "Passed: shared installer reuse, one concurrent download, offline cache, media references, checksum rejection, cancellation, ARM64 catalog selection"
        )
    }

    private static func checkCatalogs(hash: String) throws {
        let ubuntu = URL(string: "https://ubuntu.com/download/desktop")!
        let landing = try InstallerCatalog.ubuntuLandingPage(
            html:
                #"<a href="/download/desktop/thank-you?architecture=amd64&amp;lts=true">x64</a><a href="/download/desktop/thank-you?architecture=arm64&amp;version=99.04.1&amp;lts=true">ARM</a>"#,
            base: ubuntu)
        precondition(landing.absoluteString.contains("architecture=arm64"))
        let fedora = URL(string: "https://fedoraproject.org/server/download/")!
        let checksum = try InstallerCatalog.fedoraChecksumURL(
            html:
                #"<a href="https://dl.fedoraproject.org/pub/fedora/linux/releases/99/Server/aarch64/iso/Fedora-Server-99-1.1-aarch64-CHECKSUM">checksum</a><a href="https://dl.fedoraproject.org/pub/fedora/linux/releases/test/100/Server/aarch64/iso/Fedora-Server-100-aarch64-CHECKSUM">beta</a>"#,
            base: fedora, role: .minimal)
        let image = try InstallerCatalog.selectChecksums(
            "SHA256 (Fedora-Server-netinst-aarch64-99-1.1.iso) = \(hash)",
            base: checksum.deletingLastPathComponent()
        ) { $0.contains("netinst-aarch64") }
        precondition(image.url.lastPathComponent == "Fedora-Server-netinst-aarch64-99-1.1.iso")
        do {
            _ = try InstallerCatalog.selectChecksums("\(hash) *../escape.iso", base: fedora) { _ in true }
            fatalError("Unsafe paths must be rejected")
        } catch {}
    }

    private static func tryValue<T>(_ body: () throws -> T) -> T { return try! body() }
}
