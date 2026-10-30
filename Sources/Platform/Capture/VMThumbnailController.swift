import AppKit
import ScreenCaptureKit

/// Captures only this VM's own window; one bounded JPEG replaces the previous bundle thumbnail.
@MainActor
final class VMThumbnailController {
    private let destination: URL
    private var timer: Timer?
    private var capturing = false
    private var generation = 0

    init(bundle: VMBundle) { destination = bundle.url.appendingPathComponent("Thumbnail.jpg") }

    deinit { timer?.invalidate() }

    func update(view: NSView, running: Bool) {
        guard running else {
            timer?.invalidate()
            timer = nil
            generation += 1
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self, weak view] _ in
            Task { @MainActor in
                guard let self, let view else { return }
                await self.capture(view: view)
            }
        }
        timer.fireDate = Date(timeIntervalSinceNow: 5)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func capture(view: NSView) async {
        guard #available(macOS 14.4, *), !capturing, let window = view.window,
            window.isVisible, !window.isMiniaturized, !view.isHiddenOrHasHiddenAncestor,
            view.bounds.width > 0, view.bounds.height > 0
        else { return }
        capturing = true
        defer { capturing = false }
        let token = generation
        do {
            // Own-process enumeration avoids requesting access to the desktop or other applications.
            let content = try await SCShareableContent.currentProcess
            guard
                let source = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
            else { return }
            let rect = view.convert(view.bounds, to: nil)
            let configuration = SCStreamConfiguration()
            let scale = 512 / max(window.frame.width, window.frame.height)
            configuration.width = max(1, Int((window.frame.width * scale).rounded()))
            configuration.height = max(1, Int((window.frame.height * scale).rounded()))
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: configuration
            )
            guard token == generation, timer != nil else { return }
            let xScale = CGFloat(image.width) / window.frame.width
            let yScale = CGFloat(image.height) / window.frame.height
            let crop = CGRect(
                x: rect.minX * xScale, y: (window.frame.height - rect.maxY) * yScale,
                width: rect.width * xScale, height: rect.height * yScale
            ).integral
            guard let viewport = image.cropping(to: crop) else { return }
            let thumbnailScale = 256 / max(CGFloat(viewport.width), CGFloat(viewport.height))
            let width = max(1, Int((CGFloat(viewport.width) * thumbnailScale).rounded()))
            let height = max(1, Int((CGFloat(viewport.height) * thumbnailScale).rounded()))
            guard
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return }
            context.interpolationQuality = .high
            context.draw(viewport, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let thumbnail = context.makeImage() else { return }
            let bitmap = NSBitmapImageRep(cgImage: thumbnail)
            guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                return
            }
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        } catch {
            // Preserve the last successful screenshot if the window is temporarily unavailable.
        }
    }
}
