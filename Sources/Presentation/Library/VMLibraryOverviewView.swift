import AppKit

/// Library totals stay live independently of the selected VM.
@MainActor
final class VMLibraryOverviewView: NSView {
    private let storage = NSTextField(labelWithString: "Calculating storage…")
    private let storageBreakdown = NSTextField(labelWithString: "")
    private let mediaButton = NSButton(title: "Install media…", target: nil, action: nil)
    private let mediaPopover = NSPopover()
    var mediaCleanupRestriction: ((URL) -> String?)?
    private let running = NSTextField(labelWithString: "No running VMs")
    private let charts = VMLibraryChartsView()
    private var history = VMLibraryActivityHistory()
    private var timer: Timer?
    private var ticks = 0
    private var roots: [URL] = []
    private var media: URL?
    private var storageTask: Task<Void, Never>?
    var activityInput: (() -> VMLibraryActivityInput)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "Library Overview")
        title.font = .systemFont(ofSize: 28, weight: .semibold)
        storage.font = .monospacedDigitSystemFont(ofSize: 20, weight: .medium)
        storageBreakdown.textColor = .secondaryLabelColor
        storageBreakdown.toolTip =
            "Allocated file sizes. APFS clone blocks may be shared between files. Shared install media is counted once."
        running.textColor = .secondaryLabelColor
        mediaButton.target = self
        mediaButton.action = #selector(showMedia)
        mediaButton.bezelStyle = .inline
        mediaButton.toolTip = "Manage shared install media"
        let mediaLine = NSStackView(views: [storageBreakdown, mediaButton])
        mediaLine.spacing = 12
        let stack = NSStackView(views: [title, storage, mediaLine, running, charts])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        charts.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            charts.widthAnchor.constraint(equalTo: stack.widthAnchor),
            charts.heightAnchor.constraint(equalToConstant: 330),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateStorage(vmURLs: [URL], mediaURL: URL) {
        guard vmURLs != roots || mediaURL != media else { return }
        roots = vmURLs
        media = mediaURL
        refreshStorage()
    }

    private func refreshStorage() {
        guard let media else { return }
        storageTask?.cancel()
        let roots = roots
        storageTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                try? VMLibraryStorage.measure(vmURLs: roots, mediaURL: media)
            }.value
            guard !Task.isCancelled, let self else { return }
            guard let result else {
                storage.stringValue = "Storage unavailable"
                return
            }
            storage.stringValue = "\(bytes(result.vmBytes + result.mediaBytes)) used"
            storageBreakdown.stringValue = "VM files \(bytes(result.vmBytes))"
            mediaButton.title = "Install media \(bytes(result.mediaBytes))…"
        }
    }

    @objc private func showMedia() {
        guard let media else { return }
        mediaPopover.behavior = .transient
        mediaPopover.contentViewController = InstallerMediaPopoverController(
            root: media,
            restriction: { [weak self] in self?.mediaCleanupRestriction?($0) },
            changed: { [weak self] in self?.refreshStorage() })
        mediaPopover.show(relativeTo: mediaButton.bounds, of: mediaButton, preferredEdge: .maxY)
    }

    private func tick() {
        let input = activityInput?() ?? VMLibraryActivityInput(runningCount: 0, counters: [])
        history.append(input)
        running.stringValue =
            "\(input.runningCount) running · Last 2 minutes"
            + (history.unavailableCount > 0 ? " · \(history.unavailableCount) unavailable" : "")
        charts.samples = history.samples
        ticks += 1
        if ticks % 30 == 0 { refreshStorage() }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

/// Larger versions of the host CPU, memory and physical I/O histories used in VM status bars.
@MainActor
private final class VMLibraryChartsView: NSView {
    var samples: [VMActivitySample] = [] { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip =
            "Combined running VM host processes. CPU: 100% is one host core. RAM is host footprint. Disk rates are physical host I/O; cached reads may not appear."
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let latest = samples.last else { return }

        let cpu = samples.map { $0.cpuPercent }

        let memory = samples.map { $0.footprintBytes }

        let reads = samples.map { $0.readBytesPerSecond }

        let writes = samples.map { $0.writeBytesPerSecond }

        let labels = [
            "CPU  \(Int(latest.cpuPercent))%", "RAM  \(bytes(latest.footprintBytes))",
            "Disk  R \(bytes(latest.readBytesPerSecond))/s · W \(bytes(latest.writeBytesPerSecond))/s",
        ]
        setAccessibilityLabel(labels.joined(separator: ". "))
        for index in 0..<3 {
            let top = bounds.maxY - CGFloat(index) * 110
            (labels[index] as NSString).draw(
                at: NSPoint(x: 0, y: top - 20),
                withAttributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: NSColor.labelColor,
                ])
            let rect = NSRect(x: 0, y: top - 94, width: bounds.width, height: 62)
            if index == 0 { graph(cpu, rect: rect, maximum: max(100, cpu.max() ?? 0), color: .systemBlue) }
            if index == 1 {
                graph(
                    memory, rect: rect, maximum: max(1_073_741_824, memory.max() ?? 0), color: .systemPurple)
            }
            if index == 2 {
                let maximum = max(1_048_576, max(reads.max() ?? 0, writes.max() ?? 0))
                graph(reads, rect: rect, maximum: maximum, color: .systemGreen)
                graph(writes, rect: rect, maximum: maximum, color: .systemOrange)
            }
        }
    }

    private func graph(_ values: [Double], rect: NSRect, maximum: Double, color: NSColor) {
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
        color.setStroke()
        line.lineWidth = 1.5
        line.stroke()
    }

    private func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }
}
