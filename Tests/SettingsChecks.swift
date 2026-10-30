import Foundation

@main
struct SettingsChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("VirtualMacChecks-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let legacy = try JSONDecoder().decode(
            VMSettings.self,
            from: Data(
                #"{"cpu":4,"memory":4294967296,"displayWidth":2560,"displayHeight":1440,"keepHostAspectRatio":true}"#
                    .utf8))
        precondition(legacy.pixelsPerInch == nil && legacy.diskPath == nil && legacy.sharedFolders == nil)
        precondition(legacy.useMacTrackpad == nil)
        precondition((legacy.startHeadless ?? false) == false)
        precondition(legacy.displayWidth == 2560 && legacy.keepHostAspectRatio == true)
        let disk = root.appendingPathComponent("Test.img")
        try VMDiskStore.create(at: disk, capacityGB: 32)
        try VMDiskStore.validate(disk)
        let size = try fm.attributesOfItem(atPath: disk.path)[.size] as! NSNumber
        precondition(size.uint64Value == 32_000_000_000)
        let model = VMDiskStore.metadata(for: disk).appendingPathComponent("HardwareModel")
        let sentinel = Data("existing identity".utf8)
        try sentinel.write(to: model)
        do {
            try VMDiskStore.create(at: disk, capacityGB: 50)
            fatalError("Existing disks must not be overwritten")
        } catch { /* Expected exclusive-create failure. */  }
        let preservedSize = try fm.attributesOfItem(atPath: disk.path)[.size] as! NSNumber
        let preservedModel = try Data(contentsOf: model)
        precondition(preservedSize == size && preservedModel == sentinel)
        precondition(VMDiskStore.metadata(for: VMDiskStore.defaultDisk) == VMDiskStore.directory)
        let other = root.appendingPathComponent("Other.img")
        try VMDiskStore.create(at: other, capacityGB: 64)
        precondition(VMDiskStore.metadata(for: disk) != VMDiskStore.metadata(for: other))
        let unknown = root.appendingPathComponent("Unknown.img")
        try Data("not a managed disk".utf8).write(to: unknown)
        do {
            try VMDiskStore.validate(unknown)
            fatalError("Unmanaged startup disk must be rejected")
        } catch {}
        let share = SharedFolder(name: "Projects", path: root.path, readOnly: true)
        try VMDiskStore.validateShares([share])
        do {
            try VMDiskStore.validateShares([
                share, SharedFolder(name: "projects", path: root.path, readOnly: false),
            ])
            fatalError("Duplicate guest names must be rejected")
        } catch {}
        do {
            try VMDiskStore.validateShares([SharedFolder(name: "../unsafe", path: root.path, readOnly: false)]
            )
            fatalError("Invalid names must be rejected")
        } catch {}
        var updated = legacy
        updated.diskPath = disk.path
        precondition(VMDiskStore.logicalCapacity(for: updated) == 32_000_000_000)
        precondition(
            VMHardwareSummary.text(settings: updated, diskCapacity: 32_000_000_000).contains("32 GB disk"))
        updated.startHeadless = true
        updated.pixelsPerInch = 72
        updated.useMacTrackpad = true
        updated.diskPath = disk.path
        updated.restoreImagePath = root.appendingPathComponent("Installer.ipsw").path
        updated.sharedFolders = [share]
        let restored = try JSONDecoder().decode(VMSettings.self, from: JSONEncoder().encode(updated))
        precondition(restored.useMacTrackpad == true)
        precondition(restored.startHeadless == true)
        updated.startHeadless = false
        let displayStartup = try JSONDecoder().decode(VMSettings.self, from: JSONEncoder().encode(updated))
        precondition(displayStartup.startHeadless == false)
        precondition(restored.sharedFolders == [share] && restored.pixelsPerInch == 72)
        precondition(restored.diskPath == disk.path && restored.restoreImagePath == updated.restoreImagePath)
        updated.sharedFolders = []
        let noShares = try JSONDecoder().decode(VMSettings.self, from: JSONEncoder().encode(updated))
        precondition(noShares.sharedFolders?.isEmpty == true)
        print(
            "Passed: legacy migration, sparse capacity, no overwrite, per-disk identity, share validation, settings round-trip, empty sharing list"
        )
    }
}
