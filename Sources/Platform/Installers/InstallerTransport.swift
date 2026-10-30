import Foundation

protocol InstallerTransport {
    func data(from url: URL) async throws -> Data

    func download(from url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL
}

struct HTTPInstallerTransport: InstallerTransport {
    func data(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 45
        request.setValue("VirtualMac/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            try Self.validate(response)
            guard data.count < 8 * 1024 * 1024 else {
                throw settingsError("Installer release metadata is too large.")
            }
            return data
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func download(from url: URL, progress: @escaping @Sendable (Double?) -> Void) async throws -> URL {
        let transfer = InstallerTransfer(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { transfer.start(url, continuation: $0) }
        } onCancel: {
            transfer.cancel()
        }
    }

    static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https" else {
            throw settingsError("The installer server returned an invalid response.")
        }
        guard (200...299).contains(response.statusCode) else {
            throw settingsError("The installer server returned HTTP \(response.statusCode).")
        }
    }
}

/// URLSession owns its temporary file only during the delegate callback. This
/// adapter moves it to a caller-owned location and serializes cancellation/finish.
private final class InstallerTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let progress: @Sendable (Double?) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var lastProgressUpdate = 0.0

    init(progress: @escaping @Sendable (Double?) -> Void) { self.progress = progress }

    func start(_ url: URL, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("VirtualMac/1.0", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lastProgressUpdate >= 0.1 || totalBytesWritten == totalBytesExpectedToWrite else {
            return
        }
        lastProgressUpdate = now
        progress(
            totalBytesExpectedToWrite > 0
                ? min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            guard let response = downloadTask.response else {
                throw settingsError("The installer download has no response.")
            }
            try HTTPInstallerTransport.validate(response)
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let cancelled = cancelled
        let session = session
        self.session = nil
        task = nil
        lock.unlock()
        if cancelled {
            if case .success(let file) = result { try? FileManager.default.removeItem(at: file) }
            continuation?.resume(throwing: CancellationError())
        } else if let continuation {
            continuation.resume(with: result)
        } else if case .success(let file) = result {
            try? FileManager.default.removeItem(at: file)
        }
        session?.finishTasksAndInvalidate()
    }
}
