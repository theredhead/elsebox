import Foundation

struct VMLibraryActivityInput {
    var runningCount: Int
    var counters: [VMActivityCounters]
}

/// Sum independently calculated rates so starting or stopping one VM cannot spike the total.
struct VMLibraryActivityHistory {
    private var previous: [Int32: VMActivityCounters] = [:]
    private(set) var samples: [VMActivitySample] = []
    private(set) var unavailableCount = 0

    mutating func append(_ input: VMLibraryActivityInput) {
        var cpu = 0.0
        var memory = 0.0
        var reads = 0.0
        var writes = 0.0
        var current: [Int32: VMActivityCounters] = [:]
        for counter in input.counters where current[counter.processID] == nil {
            current[counter.processID] = counter
            memory += Double(counter.footprintBytes)
            if let old = previous[counter.processID], counter.timestamp > old.timestamp,
                counter.cpuNanoseconds >= old.cpuNanoseconds, counter.bytesRead >= old.bytesRead,
                counter.bytesWritten >= old.bytesWritten
            {
                let interval = counter.timestamp - old.timestamp
                cpu += Double(counter.cpuNanoseconds - old.cpuNanoseconds) / interval / 10_000_000
                reads += Double(counter.bytesRead - old.bytesRead) / interval
                writes += Double(counter.bytesWritten - old.bytesWritten) / interval
            }
        }
        previous = current
        unavailableCount = max(0, input.runningCount - current.count)
        samples.append(
            VMActivitySample(
                cpuPercent: cpu, footprintBytes: memory,
                readBytesPerSecond: reads, writeBytesPerSecond: writes))
        if samples.count > 120 { samples.removeFirst(samples.count - 120) }
    }
}
