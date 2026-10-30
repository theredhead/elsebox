import Foundation

struct VMActivityCounters {
    let processID: Int32
    let timestamp: TimeInterval
    let cpuNanoseconds: UInt64
    let footprintBytes: UInt64
    let bytesRead: UInt64
    let bytesWritten: UInt64
}

struct VMActivitySample {
    let cpuPercent: Double
    let footprintBytes: Double
    let readBytesPerSecond: Double
    let writeBytesPerSecond: Double
}

/// Converts cumulative host-process counters into rates without mixing VM boots.
struct VMActivityHistory {
    private var previous: VMActivityCounters?
    private(set) var samples: [VMActivitySample] = []
    let capacity: Int

    init(capacity: Int = 120) { self.capacity = max(1, capacity) }

    mutating func append(_ counters: VMActivityCounters) {
        defer { previous = counters }
        guard let previous, counters.processID == previous.processID,
            counters.timestamp > previous.timestamp,
            counters.cpuNanoseconds >= previous.cpuNanoseconds,
            counters.bytesRead >= previous.bytesRead, counters.bytesWritten >= previous.bytesWritten
        else {
            samples.removeAll()
            return
        }

        let interval = counters.timestamp - previous.timestamp
        samples.append(
            VMActivitySample(
                cpuPercent: Double(counters.cpuNanoseconds - previous.cpuNanoseconds) / interval / 10_000_000,
                footprintBytes: Double(counters.footprintBytes),
                readBytesPerSecond: Double(counters.bytesRead - previous.bytesRead) / interval,
                writeBytesPerSecond: Double(counters.bytesWritten - previous.bytesWritten) / interval))
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    mutating func reset() {
        previous = nil
        samples.removeAll()
    }
}
