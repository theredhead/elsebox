import AppKit

/// Compact, two-minute host-resource histories for a single VM service process.
@MainActor
final class VMActivityView: NSView {
    private var history = VMActivityHistory()
    private var timer: Timer?
    private var sample: (() -> VMActivityCounters?)?
    private var allocatedMemory: UInt64 = 0
    private var unavailable = false

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        toolTip =
            "Last 2 minutes, sampled every second. CPU: 100% is one host core. RAM: VM host-process footprint, not guest RAM usage. Disk: physical host I/O charged to the VM process; cached guest reads may not appear."
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { return NSSize(width: 234, height: 28) }

    func start(allocatedMemory: UInt64, sample: @escaping () -> VMActivityCounters?) {
        stop()
        self.allocatedMemory = allocatedMemory
        self.sample = sample
        history.reset()
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        sample = nil
        history.reset()
        unavailable = false
        needsDisplay = true
        toolTip = "VM activity: stopped"
        setAccessibilityLabel("VM activity: stopped")
    }

    private func tick() {
        if let counters = sample?() {
            unavailable = false
            history.append(counters)
        } else {
            unavailable = true
            history.reset()
        }
        if let latest = history.samples.last {
            let values =
                "CPU \(Int(latest.cpuPercent)) percent. Host RAM \(bytes(latest.footprintBytes)). Disk read \(bytes(latest.readBytesPerSecond)) per second, write \(bytes(latest.writeBytesPerSecond)) per second."
            toolTip = values + "\nLast 2 minutes. CPU 100% is one host core; RAM is host-process footprint."
            setAccessibilityLabel(
                "CPU \(Int(latest.cpuPercent)) percent. Host RAM \(bytes(latest.footprintBytes)). Disk read \(bytes(latest.readBytesPerSecond)) per second, write \(bytes(latest.writeBytesPerSecond)) per second."
            )
        } else {
            let message = unavailable ? "VM activity counters unavailable" : "Collecting VM activity"
            toolTip = message
            setAccessibilityLabel(message)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard sample != nil else { return }
        let symbols = ["cpu", "memorychip", "internaldrive"]
        for (index, symbol) in symbols.enumerated() {
            let x = CGFloat(index) * 82
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(paletteColors: [unavailable ? .tertiaryLabelColor : .secondaryLabelColor]))?
                .draw(in: NSRect(x: x, y: 7, width: 14, height: 14))
        }
        guard !history.samples.isEmpty else { return }
        let cpu = history.samples.map { $0.cpuPercent }
        let memory = history.samples.map { $0.footprintBytes }
        let reads = history.samples.map { $0.readBytesPerSecond }
        let writes = history.samples.map { $0.writeBytesPerSecond }
        graph(
            cpu, at: NSRect(x: 20, y: 4, width: 50, height: 20),
            maximum: max(100, cpu.max() ?? 0), color: .systemBlue)
        graph(
            memory, at: NSRect(x: 102, y: 4, width: 50, height: 20),
            maximum: max(Double(allocatedMemory), memory.max() ?? 0), color: .systemPurple)
        let maximum = max(1_048_576, max(reads.max() ?? 0, writes.max() ?? 0))
        graph(reads, at: NSRect(x: 184, y: 4, width: 50, height: 20), maximum: maximum, color: .systemGreen)
        graph(writes, at: NSRect(x: 184, y: 4, width: 50, height: 20), maximum: maximum, color: .systemOrange)
    }

    private func graph(_ values: [Double], at rect: NSRect, maximum: Double, color: NSColor) {
        NSColor.quaternaryLabelColor.setStroke()
        let baseline = NSBezierPath()
        baseline.move(to: NSPoint(x: rect.minX, y: rect.minY))
        baseline.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        baseline.stroke()
        let line = NSBezierPath()
        for (index, value) in values.enumerated() {
            let x = rect.maxX - Double(values.count - 1 - index) / 119 * rect.width
            let point = NSPoint(x: x, y: rect.minY + min(1, value / maximum) * rect.height)
            if index == 0 { line.move(to: point) } else { line.line(to: point) }
        }
        line.lineWidth = 1.5
        color.setStroke()
        line.stroke()
    }

    private func bytes(_ value: Double) -> String {
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
