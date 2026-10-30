import AppKit

/// A discrete scale of common resolutions, with optional host display proportions.
@MainActor
final class ResolutionPicker: NSView {
    typealias Resolution = DisplayResolution

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
        options = VMDisplayPresets.resolutions(hostAspectRatio: keepsHostAspectRatio ? hostAspectRatio : nil)
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
            options = VMDisplayPresets.resolutions(hostAspectRatio: nil)
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
