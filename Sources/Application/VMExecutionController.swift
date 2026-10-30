import Foundation
import Virtualization

/// Owns one guest's hardware lifetime and exclusive disk lease, independently of any console window.
/// Serializes boot, stop and installation finalization; presentation receives state/progress callbacks.
@MainActor
final class VMExecutionController: NSObject, @preconcurrency VZVirtualMachineDelegate {
    let bundle: VMBundle
    let network: VMNetworkMonitor

    private(set) var machine: VZVirtualMachine?
    private(set) var runtime: VMRuntime?
    private(set) var installationMedia: URL?
    private(set) var isBooting = false
    private(set) var isFinalizing = false
    private var forceStopping = false
    private var stopWasRequested = false
    private var installer: VZMacOSInstaller?
    private var lease: VMLease?

    var stateDidChange: (() -> Void)?
    var statusDidChange: ((String) -> Void)?
    var runtimeDidChange: ((VMRuntime) -> Void)?
    var runtimeDidStop: (() -> Void)?
    var restartRequested: (() -> Void)?
    var didFail: ((Error) -> Void)?
    var devicesBusy: (() -> Bool)?

    var controlsBusy: Bool { isBooting || isFinalizing }

    var hasRunningGuest: Bool { machine?.state == .running }

    var canConfigure: Bool { !controlsBusy && !forceStopping }

    var canShutDown: Bool { machine?.canRequestStop == true && !forceStopping }

    var canForceStop: Bool { machine?.canStop == true && !forceStopping }

    var isPreparingMedia: Bool { controlsBusy || InstallerPreparation.isPreparing(bundle.id) }

    var isActive: Bool {
        forceStopping || isPreparingMedia || devicesBusy?() == true
            || (machine != nil && machine?.state != .stopped && machine?.state != .error)
    }

    var canStart: Bool {
        InstallerPreparation.canStart(bundle: bundle) && !forceStopping && !isPreparingMedia
            && devicesBusy?() != true
            && (machine == nil || machine?.state == .stopped || machine?.state == .error)
    }

    var stateLabel: String {
        if forceStopping { return "Stopping…" }
        if isBooting { return installer != nil ? "Installing macOS…" : "Preparing…" }
        if isFinalizing { return "Saving settings…" }

        switch machine?.state {
        case .running: return "Running"
        case .paused: return "Paused"
        case .error: return "Stopped after error"
        default: return "Stopped"
        }
    }

    init(bundle: VMBundle) {
        self.bundle = bundle
        network = VMNetworkMonitor(bundleURL: bundle.url)
        super.init()
    }

    func start(settings: VMSettings) {
        guard canStart else { return }
        clearRuntime()
        runtimeDidStop?()
        stopWasRequested = false
        isBooting = true
        stateDidChange?()

        Task {
            defer { finishBoot() }
            do {
                lease = try VMLease(directory: bundle.url)
                let boot = makeBootCoordinator()
                let started = try await boot.start(resources: settings)
                network.start(macAddresses: started.configuration.networkDevices.map { $0.macAddress.string })
            } catch is CancellationError {
                runtimeDidStop?()
                statusDidChange?("Stopped")
            } catch {
                installer = nil
                runtimeDidStop?()
                if stopWasRequested {
                    statusDidChange?("Stopped")
                } else {
                    report(error, status: "Startup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func makeBootCoordinator() -> VMBootCoordinator {
        let boot = VMBootCoordinator(bundle: bundle)
        boot.statusDidChange = { [weak self] in self?.statusDidChange?($0) }
        boot.stateDidChange = { [weak self] in self?.stateDidChange?() }
        boot.machineDidChange = { [weak self] in self?.attach($0) }
        boot.installerDidChange = { [weak self] in
            self?.installer = $0
            self?.stateDidChange?()
        }
        return boot
    }

    private func attach(_ runtime: VMRuntime) {
        self.runtime = runtime
        installationMedia = runtime.installationMedia
        machine = runtime.machine
        machine?.delegate = self
        runtimeDidChange?(runtime)
    }

    private func finishBoot() {
        isBooting = false
        if machine == nil || machine?.state == .stopped || machine?.state == .error { clearRuntime() }
        stateDidChange?()
    }

    func shutDown() {
        guard canShutDown, let machine else { return }
        do {
            try machine.requestStop()
            stopWasRequested = true
            statusDidChange?("Shutting down…")
        } catch { report(error) }
    }

    func forceStop() {
        guard canForceStop, let machine else { return }
        stopWasRequested = true
        forceStopping = true
        statusDidChange?("Stopping…")
        stateDidChange?()

        Task {
            defer {
                forceStopping = false
                stateDidChange?()
            }
            do {
                try await machine.stop()
                network.stop()
                runtimeDidStop?()
                installer = nil
                if !isBooting { clearRuntime() }
                statusDidChange?("Stopped")
            } catch { report(error) }
        }
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        guard virtualMachine === machine else { return }
        network.stop()
        runtimeDidStop?()
        statusDidChange?("Stopped")
        if !isBooting { clearRuntime() }

        if bundle.distribution == .windows, (try? bundle.resolvedSettings().bootFromInstaller) != false {
            finishWindowsDeployment()
        }
        stateDidChange?()
    }

    private func finishWindowsDeployment() {
        isFinalizing = true
        Task {
            var installed = false
            defer {
                isFinalizing = false
                stateDidChange?()
                if installed && !stopWasRequested { restartRequested?() }
            }
            do { installed = try await VMInstallationState.finishWindowsDeployment(bundle: bundle) } catch {
                report(error, status: "Windows deployment failed")
            }
        }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        guard virtualMachine === machine else { return }
        network.stop()
        runtimeDidStop?()
        statusDidChange?("Virtual machine stopped: \(error.localizedDescription)")
        if !isBooting { clearRuntime() }
        stateDidChange?()
    }

    func releaseInstallationMedia() throws {
        try VMInstallationState.releaseMedia(bundle: bundle)
        installationMedia = nil
    }

    private func clearRuntime() {
        machine = nil
        runtime = nil
        lease = nil
    }

    private func report(_ error: Error, status: String? = nil) {
        if let status { statusDidChange?(status) }
        didFail?(error)
    }
}
