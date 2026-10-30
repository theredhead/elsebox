import Darwin
import Foundation

/// Native filesystem operations. Raw POSIX handles and errors stay in this adapter.
/// These calls have no main-thread affinity; callers can use a background task.
enum HostFileOperations {
    static func createDirectoryExclusively(at url: URL) throws {
        guard mkdir(url.path, S_IRWXU) == 0 else { throw posixError() }
    }

    static func createSparseDisk(at url: URL, capacityBytes: UInt64) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw posixError() }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.truncate(atOffset: capacityBytes)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func copyPreservingAllocation(from source: URL, to target: URL) throws {
        if clonefile(source.path, target.path, 0) != 0 {
            try FileManager.default.copyItem(at: source, to: target)
        }
    }

    private static func posixError() -> POSIXError {
        return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

/// An advisory file lock held for the lifetime of this Swift object.
/// Acquisition and release have no thread affinity. The lock file is never unlinked.
final class ExclusiveFileLease {
    private var descriptor: Int32?

    init(file: URL, createIfMissing: Bool = true, inUseMessage: String) throws {
        let descriptor = open(file.path, createIfMissing ? O_RDWR | O_CREAT : O_RDONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw settingsError(inUseMessage)
        }
        self.descriptor = descriptor
    }

    deinit {
        if let descriptor {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }
}

/// Prevents two sessions or disk imports from using the same bundle simultaneously.
final class VMLease {
    private let lease: ExclusiveFileLease

    init(directory: URL) throws {
        lease = try ExclusiveFileLease(
            file: directory.appendingPathComponent(".runtime.lock"),
            inUseMessage:
                "This virtual machine is already in use. Shut it down before opening or importing it again.")
    }
}
