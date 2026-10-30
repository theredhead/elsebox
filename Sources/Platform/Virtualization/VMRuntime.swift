import Foundation
import Virtualization

/// The hardware instance and immutable settings snapshot belonging to one boot.
struct VMRuntime {
    let machine: VZVirtualMachine
    let configuration: VZVirtualMachineConfiguration
    let settings: VMSettings
    let installationMedia: URL?

    var bootDisk: URL { VMDiskStore.disk(for: settings) }
}
