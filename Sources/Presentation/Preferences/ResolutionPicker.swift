import AppKit

/// A discrete scale of common resolutions, with optional host display proportions.
@MainActor
final class ResolutionPicker: NSView {
    struct Resolution: Equatable {
        let width: Int
        let height: Int
    }
    private let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let label = NSTextField(labelWithString: "")
    private let aspect = NSButton(
        checkboxWithTitle: "Keep host display aspect ratio", target: nil, action: nil)
    private let hostAspectRatio: Double
    private var options: [Resolution] = []
    var keepsHostAspectRatio: Bool { aspect.state == .on }
    var selectedResolution: Resolution {
        options[min(max(Int(slider.doubleValue.rounded()), 0), options.count - 1)]
    }

    static func resolutions(hostAspectRatio: Double?) -> [Resolution] {
        let presets = [
            (1024, 768), (1280, 720), (1440, 900), (1600, 900), (1920, 1080),
            (2560, 1440), (3200, 1800), (3840, 2160), (5120, 2880), (7680, 4320),
        ]
        guard let ratio = hostAspectRatio else {
            return presets.map { Resolution(width: $0.0, height: $0.1) }
        }
        // Fit each preset's long edge to landscape or portrait host proportions.
        return presets.compactMap { width, _ in
            let w = ratio >= 1 ? width : Int((Double(width) * ratio).rounded())
            let h = ratio >= 1 ? Int((Double(width) / ratio).rounded()) : width
            guard (640...7680).contains(w), (480...4320).contains(h) else { return nil }
            return Resolution(width: w, height: h)
        }
    }

    init(width: Int, height: Int, keepHostAspectRatio: Bool, hostAspectRatio: Double) {
        self.hostAspectRatio = hostAspectRatio
        super.init(frame: .zero)
        aspect.state = keepHostAspectRatio ? .on : .off
        aspect.frame = NSRect(x: 0, y: 76, width: 360, height: 24)
        aspect.target = self
        aspect.action = #selector(aspectChanged)
        slider.frame = NSRect(x: 0, y: 32, width: 360, height: 28)
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Display resolution")
        label.frame = NSRect(x: 0, y: 4, width: 360, height: 22)
        label.alignment = .center
        addSubview(aspect)
        addSubview(slider)
        addSubview(label)
        configureOptions(near: Resolution(width: width, height: height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configureOptions(near current: Resolution) {
        options = Self.resolutions(hostAspectRatio: keepsHostAspectRatio ? hostAspectRatio : nil)
        // Preserve a previously saved custom size until the user chooses another stop.
        if !keepsHostAspectRatio && !options.contains(current) && (640...7680).contains(current.width)
            && (480...4320).contains(current.height)
        {
            options.append(current)
            options.sort { $0.width == $1.width ? $0.height < $1.height : $0.width < $1.width }
        }
        // Extremely narrow or wide host layouts may have no supported preset.
        if options.isEmpty {
            aspect.state = .off
            options = Self.resolutions(hostAspectRatio: nil)
        }
        slider.maxValue = Double(options.count - 1)
        slider.numberOfTickMarks = options.count
        slider.allowsTickMarkValuesOnly = true
        let nearest = options.indices.min {
            abs(options[$0].width - current.width) + abs(options[$0].height - current.height) < abs(
                options[$1].width - current.width) + abs(options[$1].height - current.height)
        }!
        slider.doubleValue = Double(nearest)
        updateLabel()
    }

    @objc private func aspectChanged() { configureOptions(near: selectedResolution) }
    @objc private func sliderChanged() { updateLabel() }
    private func updateLabel() {
        let selected = selectedResolution
        label.stringValue = "\(selected.width) × \(selected.height) pixels"
        slider.setAccessibilityValue(label.stringValue)
    }
}
