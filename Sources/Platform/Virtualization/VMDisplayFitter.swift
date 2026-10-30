import Foundation
import Virtualization

/// Debounces guest-display resize requests and confines native display handles to the main actor.
@MainActor
final class VMDisplayFitter {
    private var task: Task<Void, Never>?

    var didFail: ((Error) -> Void)?

    func cancel() { task?.cancel() }

    func schedule(machine: VZVirtualMachine?, resources: VMSettings?, viewport: CGSize, entireDisplay: Bool) {
        task?.cancel()
        guard let resources, resources.keepHostAspectRatio == true,
            machine?.state == .running
        else { return }
        task = Task { @MainActor [weak self, weak machine] in
            do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
            guard let self, let machine, machine.state == .running,
                let display = machine.graphicsDevices.first?.displays.first
            else { return }

            let size: CGSize
            if entireDisplay {
                guard
                    let fitted = DisplayLayout.fittedSize(
                        viewport: viewport,
                        preferredWidth: resources.displayWidth ?? 1920)
                else { return }
                size = fitted
            } else {
                size = CGSize(width: resources.displayWidth ?? 1920, height: resources.displayHeight ?? 1080)
            }
            guard display.sizeInPixels != size else { return }
            do { try display.reconfigure(sizeInPixels: size) } catch {
                self.didFail?(error)
            }
        }
    }
}
