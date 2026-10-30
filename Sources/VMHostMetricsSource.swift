import Darwin
import Foundation
import ObjectiveC
import Virtualization

/// Main-thread adapter for a VM's dedicated host service process. The process lookup
/// is undocumented and checked at runtime; unavailable counters are never shown as zero.
@MainActor
enum VMHostMetricsSource {
    static func read(_ machine: VZVirtualMachine) -> VMActivityCounters? {
        guard let processID = serviceProcessID(machine), processID > 0 else { return nil }
        return processCounters(processID)
    }

    private static func serviceProcessID(_ machine: VZVirtualMachine) -> Int32? {
        let selector = NSSelectorFromString("_serviceProcessIdentifier")
        guard machine.responds(to: selector),
            let method = class_getInstanceMethod(type(of: machine), selector),
            let encoding = method_getTypeEncoding(method), String(cString: encoding).hasPrefix("i")
        else { return nil }
        typealias ReadProcessID = @convention(c) (AnyObject, Selector) -> Int32
        let read = unsafeBitCast(method_getImplementation(method), to: ReadProcessID.self)
        return read(machine, selector)
    }

    private static func processCounters(_ processID: Int32) -> VMActivityCounters? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(processID, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return VMActivityCounters(
            processID: processID, timestamp: ProcessInfo.processInfo.systemUptime,
            cpuNanoseconds: usage.ri_user_time + usage.ri_system_time,
            footprintBytes: usage.ri_phys_footprint,
            bytesRead: usage.ri_diskio_bytesread, bytesWritten: usage.ri_diskio_byteswritten)
    }
}
