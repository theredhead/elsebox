import Foundation

@main
struct LibraryOverviewChecks {
    static func main() throws {
        var history = VMLibraryActivityHistory()
        history.append(
            VMLibraryActivityInput(runningCount: 2, counters: [counter(1, 1, 0), counter(2, 1, 0)]))
        history.append(
            VMLibraryActivityInput(
                runningCount: 2,
                counters: [counter(1, 2, 1_000_000_000), counter(2, 2, 2_000_000_000)]))
        precondition(history.samples.last?.cpuPercent == 300)
        precondition(history.samples.last?.footprintBytes == 8192)
        history.append(VMLibraryActivityInput(runningCount: 1, counters: [counter(2, 3, 3_000_000_000)]))
        precondition(history.samples.last?.cpuPercent == 100)
        history.append(VMLibraryActivityInput(runningCount: 2, counters: [counter(3, 4, 50_000_000_000)]))
        precondition(history.samples.last?.cpuPercent == 0 && history.unavailableCount == 1)
        for _ in 0..<130 { history.append(VMLibraryActivityInput(runningCount: 0, counters: [])) }
        precondition(history.samples.count == 120 && history.samples.last?.footprintBytes == 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vm = root.appendingPathComponent("Test.asvm")
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let disk = vm.appendingPathComponent("Disk.img")
        FileManager.default.createFile(atPath: disk.path, contents: nil)
        let handle = try FileHandle(forWritingTo: disk)
        try handle.truncate(atOffset: 64 * 1024 * 1024)
        try handle.close()
        try Data(repeating: 1, count: 4096).write(to: vm.appendingPathComponent("VM.json"))
        try Data(repeating: 2, count: 4096).write(to: media.appendingPathComponent("Installer.iso"))
        let original = try VMLibraryStorage.measure(vmURLs: [vm], mediaURL: media)
        try FileManager.default.createSymbolicLink(
            at: vm.appendingPathComponent("External"), withDestinationURL: media)
        let repeated = try VMLibraryStorage.measure(vmURLs: [vm, vm], mediaURL: media)
        precondition(original.vmBytes == repeated.vmBytes && original.mediaBytes == repeated.mediaBytes)
        precondition(original.vmBytes > 0 && original.vmBytes < 64 * 1024 * 1024 && original.mediaBytes > 0)
        try Data([1]).write(to: media.appendingPathComponent("Index.txt"))
        try Data([1]).write(to: media.appendingPathComponent("Preparing-test.img"))
        try FileManager.default.createSymbolicLink(
            at: media.appendingPathComponent("Outside.iso"), withDestinationURL: disk)
        let inventory = try InstallerMediaInventory.files(in: media)
        precondition(inventory.count == 1 && inventory[0].url.lastPathComponent == "Installer.iso")
        precondition(!InstallerMediaInventory.isMedia(disk, inside: media))
        precondition(
            !InstallerMediaInventory.isMedia(
                media.appendingPathComponent("Preparing-test.img"), inside: media))
        precondition(!InstallerMediaInventory.canRecreate(inventory[0], root: media, downloadable: []))
        precondition(
            InstallerMediaInventory.canRecreate(inventory[0], root: media, downloadable: [inventory[0].url]))
        let digest = String(repeating: "a", count: 64)
        let bootFolder = media.appendingPathComponent("Windows Bootstrap/\(digest)")
        let sourceFolder = media.appendingPathComponent(digest)
        try FileManager.default.createDirectory(at: bootFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("Installer.iso")
        try Data([1]).write(to: source)
        let boot = CachedInstallerFile(
            url: bootFolder.appendingPathComponent("Installer-v1.img"),
            relativePath: "Windows Bootstrap/\(digest)/Installer-v1.img", allocatedBytes: 0)
        precondition(InstallerMediaInventory.canRecreate(boot, root: media, downloadable: []))
        try FileManager.default.removeItem(at: source)
        precondition(!InstallerMediaInventory.canRecreate(boot, root: media, downloadable: []))
        let suite = "nl.theredhead.virtualmac.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        RecentDiskImages.remember(disk, readOnly: true, defaults: defaults)
        RecentDiskImages.remember(disk, readOnly: false, defaults: defaults)
        precondition(RecentDiskImages.load(defaults: defaults).count == 1)
        precondition(RecentDiskImages.load(defaults: defaults).first?.readOnly == false)
        try FileManager.default.removeItem(at: disk)
        precondition(RecentDiskImages.load(defaults: defaults).isEmpty)
        print(
            "Passed: cumulative VM rates, membership changes, unavailable counters, bounded history, sparse storage, duplicate roots, media recovery locks, recent disks, inventory and symlink isolation"
        )
    }

    private static func counter(_ pid: Int32, _ time: Double, _ cpu: UInt64) -> VMActivityCounters {
        VMActivityCounters(
            processID: pid, timestamp: time, cpuNanoseconds: cpu,
            footprintBytes: 4096, bytesRead: cpu / 1000, bytesWritten: cpu / 2000)
    }
}
