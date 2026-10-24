import Foundation
import Darwin

// Process is deliberately confined behind this lock; it never blocks a Swift actor.
final class ProcessOperation: @unchecked Sendable {
    enum Interrupted: Error { case timedOut(URL) }
    private let process = Process()
    private let lock = NSLock()
    private let logURL: URL
    private let timeout: TimeInterval?
    private let warnings: [String]
    /// A program's own exit status is data; setup/server/installer failures are errors.
    private let exitStatusIsResult: Bool
    private var continuation: CheckedContinuation<OperationResult, any Error>?
    private var output: FileHandle?
    private var timer: DispatchWorkItem?
    private var interruption: (any Error)?
    private var finished = false

    init(executable: URL, arguments: [String], environment: [String: String],
         directory: URL?, logURL: URL, timeout: TimeInterval?, warnings: [String] = [],
         exitStatusIsResult: Bool = false) {
        self.logURL = logURL
        self.timeout = timeout
        self.warnings = warnings
        self.exitStatusIsResult = exitStatusIsResult
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
    }

    func run(onStart: (@Sendable () -> Void)? = nil) async throws -> OperationResult {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                DispatchQueue.global(qos: .userInitiated).async { self.start(onStart: onStart) }
            }
        } onCancel: {
            self.interrupt(CancellationError())
        }
    }

    func terminate() { interrupt(MagicWineError.stopped(logURL: logURL)) }

    private func start(onStart: (@Sendable () -> Void)?) {
        do {
            if let timeout, (!timeout.isFinite || timeout <= 0) {
                throw MagicWineError.setup("The process timeout must be positive. Log: \(logURL.path)")
            }
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                                  attributes: [.posixPermissions: 0o600]) else {
                throw MagicWineError.setup("Cannot create process log: \(logURL.path)")
            }
            let handle = try FileHandle(forWritingTo: logURL)
            output = handle
            let command = ([process.executableURL?.path ?? ""] + (process.arguments ?? []))
                .map { String(reflecting: $0) }.joined(separator: " ")
            let notes = warnings.map { "Warning: \($0)\n" }.joined()
            try handle.write(contentsOf: Data(("Command: \(command)\n\(notes)\n").utf8))
            process.standardOutput = handle
            process.standardError = handle
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [self] process in
                // A signal is not an exit status, even when the exit status is data.
                if process.terminationStatus == 0 || (exitStatusIsResult && process.terminationReason == .exit) {
                    finish(.success(OperationResult(exitCode: process.terminationStatus, logURL: logURL)))
                } else {
                    finish(.failure(MagicWineError.processFailed(exitCode: process.terminationStatus, logURL: logURL)))
                }
            }
            let shouldStart = lock.withLock { interruption == nil }
            guard shouldStart else {
                finish(.failure(CancellationError()))
                return
            }
            try process.run()
            onStart?()
            let stopImmediately = lock.withLock { interruption != nil }
            if stopImmediately { interrupt(nil) }
            if let timeout {
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.interrupt(Interrupted.timedOut(self.logURL))
                }
                lock.withLock {
                    if !finished { timer = item }
                    else { item.cancel() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            }
        } catch {
            let wrapped = (error as? MagicWineError) ?? MagicWineError.setup(
                "Could not start \(process.executableURL?.path ?? "process"): \(error.localizedDescription). Log: \(logURL.path). If macOS blocked this public Wine build, review Privacy & Security; MagicWine does not bypass Gatekeeper.")
            finish(.failure(wrapped))
        }
    }

    private func interrupt(_ error: (any Error)?) {
        lock.withLock {
            guard !finished else { return }
            if let error, interruption == nil { interruption = error }
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock {
                if !finished && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func finish(_ result: Result<OperationResult, any Error>) {
        let pending: (CheckedContinuation<OperationResult, any Error>?, (any Error)?) = lock.withLock {
            guard !finished else { return (nil, nil) }
            finished = true
            timer?.cancel()
            let value = (continuation, interruption)
            continuation = nil
            return value
        }
        guard let continuation = pending.0 else { return }
        process.terminationHandler = nil
        try? output?.close()
        if let interruption = pending.1 { continuation.resume(throwing: interruption) }
        else { continuation.resume(with: result) }
    }
}
