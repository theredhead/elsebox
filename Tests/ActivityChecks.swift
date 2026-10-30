import Foundation

@main
struct ActivityChecks {
    static func main() {
        var history = VMActivityHistory(capacity: 2)
        history.append(counters(time: 10, cpu: 1_000_000_000, read: 100, write: 200))
        precondition(history.samples.isEmpty)
        history.append(counters(time: 12, cpu: 5_000_000_000, read: 500, write: 800))
        let first = history.samples[0]
        precondition(first.cpuPercent == 200)
        precondition(first.readBytesPerSecond == 200 && first.writeBytesPerSecond == 300)
        precondition(first.footprintBytes == 4096)
        history.append(counters(time: 13, cpu: 6_000_000_000, read: 600, write: 900))
        history.append(counters(time: 14, cpu: 7_000_000_000, read: 700, write: 1000))
        precondition(history.samples.count == 2)
        history.append(counters(time: 15, cpu: 8_000_000_000, read: 1, write: 1))
        precondition(history.samples.isEmpty)
        history.append(
            VMActivityCounters(
                processID: 2, timestamp: 16, cpuNanoseconds: 9_000_000_000,
                footprintBytes: 8192, bytesRead: 2, bytesWritten: 2))
        precondition(history.samples.isEmpty)
        history.reset()
        precondition(history.samples.isEmpty)
        print("Passed: CPU/I/O rate calculation, bounded history, counter and VM-process resets")
    }

    private static func counters(time: Double, cpu: UInt64, read: UInt64, write: UInt64) -> VMActivityCounters
    {
        return VMActivityCounters(
            processID: 1, timestamp: time, cpuNanoseconds: cpu,
            footprintBytes: 4096, bytesRead: read, bytesWritten: write)
    }
}
