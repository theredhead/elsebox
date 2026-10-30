import Foundation

@main
struct LibraryChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ASVMChecks-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let library = VMLibrary(root: root.appendingPathComponent("Library"))
        try library.load()
        let alpha = try VMBundle.create(
            at: library.defaultLocation.appendingPathComponent("Alpha.asvm"), name: "Alpha", capacityGB: 32,
            mediaCache: library.mediaCache)
        let beta = try VMBundle.create(
            at: library.defaultLocation.appendingPathComponent("Beta.asvm"), name: "Beta", capacityGB: 64,
            mediaCache: library.mediaCache)
        _ = try library.register(alpha.url)
        _ = try library.register(beta.url)
        var alphaSettings = try alpha.resolvedSettings()
        alphaSettings.cpu = 2
        alphaSettings.pixelsPerInch = 96
        alphaSettings.showsStatusBar = false
        try alpha.save(alphaSettings)
        precondition(tryValue { try alpha.storedSettings().cpu } == 2)
        precondition(
            tryValue { try beta.storedSettings().cpu } == min(4, ProcessInfo.processInfo.processorCount))
        precondition(tryValue { try beta.storedSettings().pixelsPerInch } == 72)
        precondition(tryValue { try alpha.storedSettings().diskPath } == "Disk.img")
        precondition(
            tryValue { try alpha.resolvedSettings().diskPath }
                == alpha.url.appendingPathComponent("Disk.img").path)
        var firstLease: VMLease? = try VMLease(directory: alpha.url)
        do {
            _ = try VMLease(directory: alpha.url)
            fatalError("Duplicate session must fail")
        } catch {}
        var independentLease: VMLease? = try VMLease(directory: beta.url)
        withExtendedLifetime(independentLease) {}
        firstLease = nil
        let releasedLease = try VMLease(directory: alpha.url)
        withExtendedLifetime(releasedLease) {}
        // Relocation is removed from the registry, but the bundle remains intact.
        let moved = library.defaultLocation.appendingPathComponent("Renamed.asvm")
        try fm.moveItem(at: alpha.url, to: moved)
        try library.refresh()
        precondition(library.machines.count == 1 && fm.fileExists(atPath: moved.path))
        let reopened = try library.register(moved)
        precondition(reopened.id == alpha.id && tryValue { try reopened.storedSettings().cpu } == 2)
        precondition(
            tryValue { try reopened.resolvedSettings().diskPath }
                == moved.appendingPathComponent("Disk.img").path)
        let duplicate = root.appendingPathComponent("Duplicate.asvm")
        try fm.copyItem(at: moved, to: duplicate)
        do {
            _ = try library.register(duplicate)
            fatalError("Duplicate identity must fail")
        } catch {}
        try library.remove(beta.id)
        precondition(fm.fileExists(atPath: beta.url.path))
        let reloaded = VMLibrary(root: library.root)
        try reloaded.load()
        precondition(reloaded.machines.count == 1 && reloaded.machines[0].id == alpha.id)
        // A selected local restore image is copied in, and its path survives relocation.
        let ipsw = root.appendingPathComponent("Fixture.ipsw")
        try Data("restore fixture".utf8).write(to: ipsw)
        var settings = try reopened.resolvedSettings()
        settings.restoreImagePath = ipsw.path
        try reopened.save(settings)
        let installerPath = try reopened.storedSettings().restoreImagePath!
        precondition(
            !installerPath.hasPrefix("/")
                && tryValue { try Data(contentsOf: reopened.mediaCache.resolve(installerPath)) }
                    == Data("restore fixture".utf8)
        )
        do {
            _ = try reopened.assetURL("../outside.img")
            fatalError("Traversal must fail")
        } catch {}
        var importSettings = try reopened.resolvedSettings()
        importSettings.diskPath = beta.url.appendingPathComponent("Disk.img").path
        do {
            try reopened.save(importSettings)
            fatalError("Importing a running VM disk must fail")
        } catch {}
        independentLease = nil
        try reopened.save(importSettings)
        let importedPath = try reopened.storedSettings().diskPath!
        precondition(importedPath.hasPrefix("Disks/") && !importedPath.hasPrefix("/"))
        try VMDiskStore.validate(reopened.assetURL(importedPath))
        // Legacy migration keeps identity and disk, leaves the original untouched, and runs once.
        let legacy = root.appendingPathComponent("Legacy")
        let migration = VMLibrary(root: legacy)
        try migration.load()
        let oldDisk = legacy.appendingPathComponent("Disk.img")
        try VMDiskStore.create(at: oldDisk, capacityGB: 32)
        let hardware = Data("hardware fixture".utf8)
        try hardware.write(to: legacy.appendingPathComponent("HardwareModel"))
        try Data("machine fixture".utf8).write(to: legacy.appendingPathComponent("MachineIdentifier"))
        try Data().write(to: legacy.appendingPathComponent("Installed"))
        var oldSettings = Resources(cpu: 3, memory: 8 * 1_073_741_824)
        oldSettings.diskPath = oldDisk.path
        try JSONEncoder().encode(oldSettings).write(to: legacy.appendingPathComponent("Resources.json"))
        try migration.migrateLegacyIfNeeded(from: legacy)
        precondition(migration.machines.count == 1)
        let migrated = migration.machines[0]
        precondition(tryValue { try migrated.storedSettings().cpu } == 3)
        precondition(
            tryValue { try Data(contentsOf: migrated.url.appendingPathComponent("HardwareModel")) }
                == hardware)
        precondition(
            fm.fileExists(atPath: oldDisk.path)
                && fm.fileExists(atPath: migrated.url.appendingPathComponent("Installed").path))
        try migration.migrateLegacyIfNeeded(from: legacy)
        precondition(migration.machines.count == 1)
        print(
            "Passed: per-VM settings, relative assets, relocation/pruning, duplicate identity, registry persistence, independent session locks, bundled installer, traversal rejection, legacy migration and backup"
        )
        withExtendedLifetime(firstLease) {}
    }
    private static func tryValue<T>(_ body: () throws -> T) -> T { try! body() }
}
