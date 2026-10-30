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

    override var intrinsicContentSize: NSSize { return NSSize(width: 600, height: 28) }

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
            setAccessibilityLabel(
                "CPU \(Int(latest.cpuPercent)) percent. Host RAM \(bytes(latest.footprintBytes)). Disk read \(bytes(latest.readBytesPerSecond)) per second, write \(bytes(latest.writeBytesPerSecond)) per second."
            )
        } else {
            setAccessibilityLabel(unavailable ? "VM activity counters unavailable" : "Collecting VM activity")
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard sample != nil else { return }
        guard let latest = history.samples.last else {
            drawText(unavailable ? "Activity unavailable" : "Collecting activity…", at: NSPoint(x: 4, y: 7))
            return
        }
        let firstColumn = bounds.width * 0.24
        let secondColumn = bounds.width * 0.50
        let cpu = history.samples.map { $0.cpuPercent }
        let memory = history.samples.map { $0.footprintBytes }
        let reads = history.samples.map { $0.readBytesPerSecond }
        let writes = history.samples.map { $0.writeBytesPerSecond }
        drawText("CPU \(Int(latest.cpuPercent))%", at: NSPoint(x: 4, y: 7))
        graph(
            cpu, at: NSRect(x: firstColumn - 64, y: 4, width: 56, height: 20),
            maximum: max(100, cpu.max() ?? 0), color: .systemBlue)
        drawText("RAM \(bytes(latest.footprintBytes))", at: NSPoint(x: firstColumn + 4, y: 7))
        graph(
            memory, at: NSRect(x: secondColumn - 64, y: 4, width: 56, height: 20),
            maximum: max(Double(allocatedMemory), memory.max() ?? 0), color: .systemPurple)
        drawText(
            "R \(bytes(latest.readBytesPerSecond))/s  W \(bytes(latest.writeBytesPerSecond))/s",
            at: NSPoint(x: secondColumn + 4, y: 7))
        let maximum = max(1_048_576, max(reads.max() ?? 0, writes.max() ?? 0))
        graph(
            reads, at: NSRect(x: bounds.width - 64, y: 4, width: 56, height: 20), maximum: maximum,
            color: .systemGreen)
        graph(
            writes, at: NSRect(x: bounds.width - 64, y: 4, width: 56, height: 20), maximum: maximum,
            color: .systemOrange)
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

    private func drawText(_ text: String, at point: NSPoint) {
        (text as NSString).draw(
            at: point,
            withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
    }

    private func bytes(_ value: Double) -> String {
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
