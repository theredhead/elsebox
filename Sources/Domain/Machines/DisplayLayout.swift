import Foundation

/// Guest dimensions for the actual drawable viewport, preserving the selected width
/// when possible and keeping requests inside the supported preference bounds.
enum DisplayLayout {
    static func fittedSize(viewport: CGSize, preferredWidth: Int) -> CGSize? {
        guard viewport.width.isFinite, viewport.height.isFinite,
            viewport.width > 0, viewport.height > 0
        else { return nil }

        let ratio = viewport.width / viewport.height
        let lowerWidth = max(640.0, 480.0 * ratio)
        let upperWidth = min(7680.0, 4320.0 * ratio)
        guard lowerWidth <= upperWidth else { return nil }

        let width = min(max(Double(preferredWidth), lowerWidth), upperWidth).rounded()
        let height = (width / ratio).rounded()
        return CGSize(width: width, height: height)
    }
}

/// A guest pixel size, independent of any picker or native window.
struct DisplayResolution: Equatable {
    let width: Int
    let height: Int
}

/// Supplies the common display sizes shared by preferences and boot-time aspect matching.
enum VMDisplayPresets {
    static func resolutions(hostAspectRatio: Double?) -> [DisplayResolution] {
        let presets = [
            (1024, 768), (1280, 720), (1440, 900), (1600, 900), (1920, 1080),
            (2560, 1440), (3200, 1800), (3840, 2160), (5120, 2880), (7680, 4320),
        ]
        guard let ratio = hostAspectRatio else {
            return presets.map { DisplayResolution(width: $0.0, height: $0.1) }
        }
        // Fit each preset's long edge to landscape or portrait host proportions.
        return presets.compactMap { width, _ in
            let w = ratio >= 1 ? width : Int((Double(width) * ratio).rounded())
            let h = ratio >= 1 ? Int((Double(width) / ratio).rounded()) : width
            guard (640...7680).contains(w), (480...4320).contains(h) else { return nil }
            return DisplayResolution(width: w, height: h)
        }
    }
}
