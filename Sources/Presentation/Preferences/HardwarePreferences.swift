import AppKit

/// Owns CPU, memory and display/input choices, preserving the fixed Windows boot display contract.
@MainActor
final class HardwarePreferences {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
    private let cpu = NSPopUpButton()
    private let memory = NSPopUpButton()
    private let density = NSTextField()
    private let input = NSPopUpButton()
    private let resolution: ResolutionPicker
    private let isWindows: Bool

    init(
        settings: VMSettings, cpuLimits: ClosedRange<Int>, memoryLimits: ClosedRange<Int>,
        hostAspectRatio: Double, distribution: GuestDistribution
    ) {
        isWindows = distribution == .windows
        let usesEFI = distribution.usesEFI
        resolution = ResolutionPicker(
            width: settings.displayWidth ?? 1920, height: settings.displayHeight ?? 1080,
            keepHostAspectRatio: settings.keepHostAspectRatio ?? false, hostAspectRatio: hostAspectRatio)
        let general = view
        for value in cpuLimits where !isWindows || value >= 2 {
            cpu.addItem(withTitle: "\(value)")
            cpu.lastItem?.tag = value
        }
        cpu.selectItem(
            withTag: min(
                max(
                    settings.cpu,
                    max(
                        cpuLimits.lowerBound,
                        isWindows ? 2 : 1)), cpuLimits.upperBound))
        for value in memoryLimits where !isWindows || value >= 4 {
            memory.addItem(withTitle: "\(value) GiB")
            memory.lastItem?.tag = value
        }

        let selectedMemory = Int((settings.memory + 1_073_741_823) / 1_073_741_824)
        memory.selectItem(
            withTag: min(
                max(
                    selectedMemory,
                    max(
                        memoryLimits.lowerBound,
                        isWindows ? 4 : 1)), memoryLimits.upperBound))
        PreferenceForm.field(cpu, label: "CPU cores:", y: 305, in: general)
        PreferenceForm.field(memory, label: "Memory:", y: 265, in: general)
        resolution.frame = NSRect(x: 20, y: 132, width: 360, height: 110)
        general.addSubview(resolution)
        density.stringValue = String(settings.pixelsPerInch ?? 72)
        density.setAccessibilityLabel("Display density in pixels per inch")
        PreferenceForm.field(density, label: "Display density (PPI):", y: 87, in: general)
        input.addItems(withTitles: ["USB mouse", "Mac trackpad"])
        input.selectItem(at: !usesEFI && settings.useMacTrackpad == true ? 1 : 0)
        input.isEnabled = !usesEFI
        density.isEnabled = !usesEFI
        PreferenceForm.field(input, label: "Pointer input:", y: 47, in: general)
        input.setFrameSize(NSSize(width: 320, height: 26))
        input.setAccessibilityLabel("Pointer input mode")

        if isWindows {
            resolution.isHidden = true
            density.isHidden = true
            input.isHidden = true
            for view in general.subviews where view is NSTextField && view.frame.minY < 240 {
                view.isHidden = true
            }
        }
    }

    func apply(to result: inout VMSettings) throws {
        guard let ppi = Int(density.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
            (36...300).contains(ppi)
        else { throw settingsError("Display density must be a whole number between 36 and 300 PPI.") }
        result.cpu = cpu.selectedTag()
        result.memory = UInt64(memory.selectedTag()) * 1_073_741_824
        result.displayWidth = resolution.selectedResolution.width
        result.displayHeight = resolution.selectedResolution.height
        result.keepHostAspectRatio = resolution.keepsHostAspectRatio
        result.pixelsPerInch = ppi
        result.useMacTrackpad = input.indexOfSelectedItem == 1
        if isWindows {
            result.displayWidth = 1024
            result.displayHeight = 768
            result.keepHostAspectRatio = false
            result.pixelsPerInch = 72
            result.useMacTrackpad = false
        }
    }
}
