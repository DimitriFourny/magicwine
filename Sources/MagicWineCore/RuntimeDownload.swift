import Foundation

// Sample at presentation cadence using bytes received since the previous sample.
// Long notification gaps stay in the elapsed time, so slow transfers retain a measured rate.
struct DownloadProgressSampler {
    private static let interval: TimeInterval = 0.25
    private var receivedBytes: Int64 = 0
    private var lastObservation: TimeInterval
    private var sampleTime: TimeInterval
    private var sampleBytes: Int64 = 0
    private var sampledSpeed: Double = 0
    private var lastEmission: TimeInterval?
    private var finished = false

    init(now: TimeInterval) {
        lastObservation = now
        sampleTime = now
    }

    mutating func record(receivedBytes: Int64, totalBytes: Int64?, now: TimeInterval,
                         finished: Bool = false) -> WineDownloadProgress? {
        guard !self.finished else { return nil }
        let now = max(lastObservation, now)
        self.receivedBytes = max(self.receivedBytes, receivedBytes)
        lastObservation = now
        guard finished || lastEmission == nil || now - lastEmission! >= Self.interval else { return nil }
        let elapsed = now - sampleTime
        // Sub-millisecond intervals are not useful rate measurements, including
        // a final callback immediately following the last transfer callback.
        if elapsed >= 0.001 {
            sampledSpeed = Double(self.receivedBytes - sampleBytes) / elapsed
            sampleTime = now
            sampleBytes = self.receivedBytes
        }
        lastEmission = now
        self.finished = finished
        return WineDownloadProgress(receivedBytes: self.receivedBytes, totalBytes: totalBytes,
                                    bytesPerSecond: sampledSpeed)
    }
}

enum RuntimeDownload {
    static func download(for request: URLRequest,
                         progress: (@Sendable (WineDownloadProgress) -> Void)? = nil) async throws -> (URL, URLResponse) {
        guard let progress else { return try await URLSession.shared.download(for: request) }
        let operation = DownloadOperation(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.start(request: request, continuation: continuation)
            }
        } onCancel: {
            operation.cancel()
        }
    }

    private final class DownloadOperation: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        typealias Completion = CheckedContinuation<(URL, URLResponse), any Error>
        typealias Outcome = Result<(URL, URLResponse), any Error>
        private let lock = NSLock()
        private var sampler: DownloadProgressSampler
        private let progress: @Sendable (WineDownloadProgress) -> Void
        private var continuation: Completion?
        private var session: URLSession?
        private var task: URLSessionDownloadTask?
        private var outcome: Outcome?
        private var cancelled = false

        private static var now: TimeInterval {
            Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        }

        init(progress: @escaping @Sendable (WineDownloadProgress) -> Void) {
            self.progress = progress
            sampler = DownloadProgressSampler(now: Self.now)
            super.init()
        }

        func start(request: URLRequest, continuation: Completion) {
            lock.withLock {
                guard !cancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                // Completion-handler/async adapters can consume download delegate
                // notifications. Own this task so actual byte updates reach us.
                let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request)
                self.task = task
                report(receivedBytes: 0, totalBytes: nil)
                task.resume()
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                task?.cancel()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            lock.withLock {
                guard continuation != nil, !cancelled else { return }
                report(receivedBytes: totalBytesWritten, totalBytes: totalBytesExpectedToWrite)
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            lock.withLock {
                guard continuation != nil, !cancelled else { return }
                do {
                    guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
                    let manager = FileManager.default
                    let attributes = try manager.attributesOfItem(atPath: location.path)
                    guard let bytes = (attributes[.size] as? NSNumber)?.int64Value else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    let destination = manager.temporaryDirectory.appendingPathComponent("magicwine-download-\(UUID().uuidString)")
                    // Foundation deletes location after this delegate returns.
                    // Transfer ownership by moving it, without buffering the body.
                    try manager.moveItem(at: location, to: destination)
                    outcome = .success((destination, response))
                    report(receivedBytes: bytes, totalBytes: response.expectedContentLength, finished: true)
                } catch {
                    outcome = .failure(error)
                }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let completion: (Completion, Outcome, URLSession?)? = lock.withLock {
                guard let continuation else { return nil }
                let result: Outcome
                if cancelled {
                    result = .failure(CancellationError())
                } else if let error {
                    result = .failure(error)
                } else {
                    result = outcome ?? .failure(URLError(.badServerResponse))
                }
                if case let .success((file, _)) = outcome, case .failure = result {
                    try? FileManager.default.removeItem(at: file)
                }
                let ownedSession = self.session
                self.continuation = nil
                self.session = nil
                self.task = nil
                outcome = nil
                return (continuation, result, ownedSession)
            }
            guard let (continuation, result, ownedSession) = completion else { return }
            ownedSession?.finishTasksAndInvalidate()
            continuation.resume(with: result)
        }

        // Caller holds lock; callbacks and final completion remain ordered.
        private func report(receivedBytes: Int64, totalBytes: Int64?, finished: Bool = false) {
            if let update = sampler.record(receivedBytes: receivedBytes, totalBytes: totalBytes,
                                           now: Self.now, finished: finished) {
                progress(update)
            }
        }
    }
}
