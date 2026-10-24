import Foundation
import Darwin

// Process is deliberately confined behind this lock; it never blocks a Swift actor.
final class ProcessOperation: @unchecked Sendable {
    enum Interrupted: Error { case timedOut(URL) }

    enum Output {
        /// Program, installer, and setup logs: the command header and combined output,
        /// capped at `outputLimit` bytes of output. A detached `ProcessLogDrain` writes it,
        /// so output of Windows processes that outlive MagicWine still reaches the log.
        case log(ProcessLogFile)
        /// Internal probes (`wineserver -w/-k`, `--version`): output stays in a bounded
        /// memory buffer and becomes a log in `directory` only when the probe fails, times
        /// out, or is stopped. A stop reports `stoppedLog` instead when given.
        case probe(directory: URL, operation: String, detail: String?, stoppedLog: URL? = nil)
    }

    private enum Interruption { case cancelled, stopped, timedOut }
    private enum Outcome {
        case exited(Int32, Process.TerminationReason)
        case notStarted(any Error)
    }

    /// The most recent probe output kept in memory.
    static let probeLimit = 64 * 1_024

    private let process = Process()
    private let lock = NSLock()
    private let output: Output
    private let outputLimit: Int
    /// Tests turn this off to exercise the in-process writer used when the helper is missing.
    private let detachedLogWriter: Bool
    private let timeout: TimeInterval?
    private let warnings: [String]
    /// A program's own exit status is data; setup/server/installer failures are errors.
    private let exitStatusIsResult: Bool
    private var continuation: CheckedContinuation<Int32, any Error>?
    private var capture: ProcessOutputCapture?
    private var drain: ProcessLogDrain?
    private var timer: DispatchWorkItem?
    private var interruption: Interruption?
    private var finished = false
    private var persistedProbeLog: URL?

    init(executable: URL, arguments: [String], environment: [String: String],
         directory: URL?, output: Output, timeout: TimeInterval?, warnings: [String] = [],
         exitStatusIsResult: Bool = false, outputLimit: Int = ProcessLogs.outputLimit,
         detachedLogWriter: Bool = true) {
        self.output = output
        self.outputLimit = outputLimit
        self.detachedLogWriter = detachedLogWriter
        self.timeout = timeout
        self.warnings = warnings
        self.exitStatusIsResult = exitStatusIsResult
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
    }

    /// Runs a `.log` operation; its log stays readable at `OperationResult.logURL`.
    func run(onStart: (@Sendable () -> Void)? = nil) async throws -> OperationResult {
        guard case .log(let file) = output else { preconditionFailure("A probe has no log to return.") }
        return OperationResult(exitCode: try await perform(onStart: onStart), logURL: file.url)
    }

    /// Runs a `.probe` operation and returns its status (nonzero only with
    /// `exitStatusIsResult`) and captured output.
    func probe() async throws -> (status: Int32, output: Data) {
        let status = try await perform(onStart: nil)
        return (status, capture?.captured() ?? Data())
    }

    /// Persists a probe's output when its caller rejects a successful result.
    func recordProbeLog(note: String) throws -> URL {
        try persistProbe(note: note)
    }

    func terminate() { interrupt(.stopped) }

    private var header: Data {
        let command = ([process.executableURL?.path ?? ""] + (process.arguments ?? []))
            .map { String(reflecting: $0) }.joined(separator: " ")
        let notes = warnings.map { "Warning: \($0)\n" }.joined()
        return Data("Command: \(command)\n\(notes)\n".utf8)
    }

    private func perform(onStart: (@Sendable () -> Void)?) async throws -> Int32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation }
                DispatchQueue.global(qos: .userInitiated).async { self.start(onStart: onStart) }
            }
        } onCancel: {
            self.interrupt(.cancelled)
        }
    }

    private func start(onStart: (@Sendable () -> Void)?) {
        let writeEnd: FileHandle
        do {
            switch output {
            case .log(let file):
                file.write(header)
                if detachedLogWriter, let drain = ProcessLogDrain(log: file, limit: outputLimit) {
                    lock.withLock { self.drain = drain }
                    writeEnd = drain.writeEnd
                } else {
                    // Without the helper the log is written in-process, until MagicWine exits.
                    let capture = try ProcessOutputCapture(sink: .file(file, limit: outputLimit))
                    lock.withLock { self.capture = capture }
                    capture.start()
                    writeEnd = capture.writeEnd
                }
            case .probe:
                let capture = try ProcessOutputCapture(sink: .memory(limit: Self.probeLimit))
                lock.withLock { self.capture = capture }
                capture.start()
                writeEnd = capture.writeEnd
            }
        } catch {
            if case .log(let file) = output { file.close() }
            finish(.notStarted(error))
            return
        }
        do {
            if let timeout, (!timeout.isFinite || timeout <= 0) {
                throw MagicWineError.setup("The process timeout must be positive.")
            }
            process.standardOutput = writeEnd
            process.standardError = writeEnd
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [self] process in
                finish(.exited(process.terminationStatus, process.terminationReason))
            }
            let shouldStart = lock.withLock { interruption == nil }
            guard shouldStart else {
                try? writeEnd.close()
                finish(.notStarted(CancellationError()))
                return
            }
            // No pipe created concurrently by another operation may leak into this child.
            try ProcessOutputCapture.descriptorLock.withLock { try process.run() }
            // The child holds its own copy; EOF then follows the last writer's exit.
            try? writeEnd.close()
            onStart?()
            let stopImmediately = lock.withLock { interruption != nil }
            if stopImmediately { interrupt(nil) }
            if let timeout {
                let item = DispatchWorkItem { [weak self] in self?.interrupt(.timedOut) }
                lock.withLock {
                    if !finished { timer = item }
                    else { item.cancel() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
            }
        } catch {
            try? writeEnd.close()
            finish(.notStarted(error))
        }
    }

    private func interrupt(_ reason: Interruption?) {
        lock.withLock {
            guard !finished else { return }
            if let reason, interruption == nil { interruption = reason }
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.withLock {
                if !finished && process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    private func finish(_ outcome: Outcome) {
        let pending: (CheckedContinuation<Int32, any Error>?, Interruption?, ProcessOutputCapture?, ProcessLogDrain?) = lock.withLock {
            guard !finished else { return (nil, nil, nil, nil) }
            finished = true
            timer?.cancel()
            let value = (continuation, interruption, capture, drain)
            continuation = nil
            return value
        }
        guard let continuation = pending.0 else { return }
        process.terminationHandler = nil
        // Everything the process wrote before exiting is in its log or buffer now; detached
        // children that inherited the pipe keep appending until they exit.
        pending.2?.flush()
        pending.3?.flush()
        pending.3?.detach()
        continuation.resume(with: result(outcome, interruption: pending.1))
    }

    private func result(_ outcome: Outcome, interruption: Interruption?) -> Result<Int32, any Error> {
        do {
            switch interruption {
            case .cancelled: return .failure(CancellationError())
            case .stopped:
                if case .probe(_, _, _, let stoppedLog?) = output { return .failure(MagicWineError.stopped(logURL: stoppedLog)) }
                return .failure(MagicWineError.stopped(logURL: try failureLog(note: "Stopped by MagicWine.")))
            case .timedOut:
                return .failure(Interrupted.timedOut(try failureLog(note: "Timed out after \(timeout ?? 0) seconds.")))
            case nil: break
            }
            switch outcome {
            case .exited(let status, let reason):
                // A signal is not an exit status, even when the exit status is data.
                if status == 0 || (exitStatusIsResult && reason == .exit) { return .success(status) }
                let note = reason == .exit ? "Exited with status \(status)." : "Terminated by signal \(status)."
                return .failure(MagicWineError.processFailed(exitCode: status, logURL: try failureLog(note: note)))
            case .notStarted(let error):
                if error is CancellationError { return .failure(error) }
                let log = try failureLog(note: "Could not start: \(error.localizedDescription)")
                return .failure(MagicWineError.setup(
                    "Could not start \(process.executableURL?.path ?? "process"): \(error.localizedDescription). Log: \(log.path). If macOS blocked this public Wine build, review Privacy & Security; MagicWine does not bypass Gatekeeper."))
            }
        } catch {
            return .failure(error)
        }
    }

    /// The operation's log; a probe's buffered output is written out first.
    private func failureLog(note: String) throws -> URL {
        switch output {
        case .log(let file): return file.url
        case .probe: return try persistProbe(note: note)
        }
    }

    private func persistProbe(note: String) throws -> URL {
        guard case .probe(let directory, let operation, let detail, _) = output else {
            preconditionFailure("Only probes persist their output on demand.")
        }
        if let existing = lock.withLock({ persistedProbeLog }) { return existing }
        let contents = header + (capture?.captured() ?? Data()) + Data("\nMagicWine: \(note)\n".utf8)
        let url = try ProcessLogFile.record(contents, in: directory, operation: operation, detail: detail)
        lock.withLock { persistedProbeLog = url }
        return url
    }
}

/// Drains a child's combined stdout/stderr pipe continuously so the child never blocks
/// on a full pipe or a slow log, and bounds what is kept: a log stops growing after its
/// limit with one truncation marker, a probe buffer keeps only its most recent bytes.
final class ProcessOutputCapture: @unchecked Sendable {
    enum Sink {
        case file(ProcessLogFile, limit: Int)
        case memory(limit: Int)
    }

    let writeEnd: FileHandle
    private let readDescriptor: Int32
    private let sink: Sink
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MagicWine.ProcessOutputCapture", qos: .utility)
    private var source: DispatchSourceRead?
    private var closed = false
    private var written = 0
    private var truncated = false
    private var buffer = Data()
    private var dropped = false
    private let chunk = UnsafeMutableRawBufferPointer.allocate(byteCount: 65_536, alignment: 1)

    /// Held while creating close-on-exec descriptors and while spawning children, so a
    /// pipe of one operation never leaks into another operation's child (macOS has no
    /// `pipe2`, and `Process` children inherit every descriptor without close-on-exec).
    static let descriptorLock = NSLock()

    /// A pipe whose ends are both close-on-exec.
    static func makePipe() throws -> (read: Int32, write: Int32) {
        try descriptorLock.withLock {
            var descriptors: [Int32] = [-1, -1]
            guard pipe(&descriptors) == 0 else {
                throw MagicWineError.setup("Cannot create an output pipe: \(String(cString: strerror(errno))).")
            }
            for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
            return (descriptors[0], descriptors[1])
        }
    }

    init(sink: Sink) throws {
        let descriptors = try Self.makePipe()
        _ = fcntl(descriptors.read, F_SETFL, fcntl(descriptors.read, F_GETFL) | O_NONBLOCK)
        readDescriptor = descriptors.read
        writeEnd = FileHandle(fileDescriptor: descriptors.write, closeOnDealloc: false)
        self.sink = sink
    }

    deinit { chunk.deallocate() }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: readDescriptor, queue: queue)
        source.setEventHandler { [self] in
            if lock.withLock({ drainLocked() }) { source.cancel() }
        }
        // The source keeps the capture alive until the last writer closes the pipe.
        source.setCancelHandler { [self] in
            lock.withLock {
                closed = true
                Darwin.close(readDescriptor)
                self.source = nil
            }
            if case .file(let file, _) = sink { file.close() }
        }
        lock.withLock { self.source = source }
        source.resume()
    }

    /// Moves everything already in the pipe to the sink before returning.
    func flush() { lock.withLock { _ = drainLocked() } }

    func captured() -> Data {
        lock.withLock { dropped ? Data("[Earlier output omitted]\n".utf8) + buffer : buffer }
    }

    /// Reads until the pipe is empty; true at end of file.
    private func drainLocked() -> Bool {
        guard !closed else { return true }
        while true {
            let count = read(readDescriptor, chunk.baseAddress, chunk.count)
            if count > 0 { consume(UnsafeRawBufferPointer(rebasing: chunk[0..<count])) }
            else if count == 0 { return true }
            else if errno == EINTR { continue }
            else { return errno != EAGAIN && errno != EWOULDBLOCK }
        }
    }

    private func consume(_ bytes: UnsafeRawBufferPointer) {
        switch sink {
        case .file(let file, let limit):
            guard !truncated else { return }
            let room = limit - written
            if bytes.count <= room {
                file.write(bytes)
                written += bytes.count
            } else {
                file.write(UnsafeRawBufferPointer(rebasing: bytes[0..<room]))
                written = limit
                truncated = true
                file.write(Data(ProcessLogDrain.truncationMarker(limit: limit).utf8))
            }
        case .memory(let limit):
            buffer.append(contentsOf: bytes)
            if buffer.count > limit {
                buffer.removeFirst(buffer.count - limit)
                dropped = true
            }
        }
    }
}

/// A detached helper process (`/usr/bin/perl`, started in its own process group with only
/// the descriptors below) that owns the read end of a child's output pipe and the log
/// descriptor, so output of Windows processes that outlive MagicWine or the CLI still
/// reaches the log. It writes up to `limit` bytes, then the truncation marker once, then
/// reads and discards until the last writer closes the pipe. Because it inherits the
/// log's shared `flock`, the log counts as running until then. While MagicWine runs, a
/// control pipe lets `flush` wait until everything already in the pipe is in the log.
final class ProcessLogDrain: @unchecked Sendable {
    static let helper = "/usr/bin/perl"
    // fd 0: output pipe, 1: log, 3: flush requests, 4: acknowledgements.
    static let script = #"""
    use strict; use Fcntl;
    $SIG{PIPE} = 'IGNORE';
    my ($limit, $marker) = @ARGV;
    my ($written, $truncated, $eof) = (0, 0, 0);
    my ($control, $ack);
    unless (open($control, '<&=', 3) && open($ack, '>&=', 4)) { ($control, $ack) = (undef, undef); }
    fcntl(STDIN, F_SETFL, fcntl(STDIN, F_GETFL, 0) | O_NONBLOCK);
    sub put {
        my ($data) = @_; my $offset = 0;
        while ($offset < length $data) {
            my $count = syswrite(STDOUT, $data, length($data) - $offset, $offset);
            if (!defined $count) { next if $!{EINTR}; return; }
            $offset += $count;
        }
    }
    sub take {
        my ($data) = @_;
        return if $truncated;
        my $room = $limit - $written;
        if (length($data) <= $room) { put($data); $written += length $data; return; }
        put(substr($data, 0, $room)); $written = $limit; $truncated = 1; put($marker);
    }
    sub drain {
        while (1) {
            my $count = sysread(STDIN, my $buffer, 65536);
            if (!defined $count) { next if $!{EINTR}; return if $!{EAGAIN} || $!{EWOULDBLOCK}; $eof = 1; return; }
            if ($count == 0) { $eof = 1; return; }
            take($buffer);
        }
    }
    until ($eof) {
        my $wanted = ''; vec($wanted, 0, 1) = 1;
        vec($wanted, fileno($control), 1) = 1 if $control;
        my $ready = select(my $readable = $wanted, undef, undef, undef);
        if ($ready < 0) { next if $!{EINTR}; last; }
        drain() if vec($readable, 0, 1);
        if ($control && vec($readable, fileno($control), 1)) {
            my $count = sysread($control, my $request, 64);
            drain() unless $eof;
            if ($count) { syswrite($ack, 'D'); } else { close($control); close($ack); ($control, $ack) = (undef, undef); }
        }
    }
    """#

    static func truncationMarker(limit: Int) -> String {
        let size = limit % 1_048_576 == 0 ? "\(limit / 1_048_576) MiB" : "\(limit) bytes"
        return "\n[MagicWine: log truncated after \(size) of output; further output was discarded while the process kept running.]\n"
    }

    let writeEnd: FileHandle
    private let lock = NSLock()
    private var control: Int32
    private var acknowledgement: Int32
    private let pid: pid_t
    private let directory: URL
    private var exitSource: DispatchSourceProcess?
    private var exited = false

    /// Starts the helper and hands it the log, or returns nil (nothing changed) when it
    /// cannot start, in which case the caller writes the log in-process.
    init?(log: ProcessLogFile, limit: Int) {
        guard FileManager.default.isExecutableFile(atPath: Self.helper),
              let output = try? ProcessOutputCapture.makePipe() else { return nil }
        guard let requests = try? ProcessOutputCapture.makePipe() else {
            close(output.read); close(output.write); return nil
        }
        guard let replies = try? ProcessOutputCapture.makePipe() else {
            [output.read, output.write, requests.read, requests.write].forEach { close($0) }; return nil
        }
        // Sources above the targets, so no dup2 overwrites a source it still needs.
        let sources = [output.read, log.descriptor, requests.read, replies.write].map { fcntl($0, F_DUPFD_CLOEXEC, 10) }
        defer { sources.filter { $0 >= 0 }.forEach { close($0) } }
        let parentOnly = [output.read, requests.read, replies.write]
        guard sources.allSatisfy({ $0 >= 0 }), let pid = Self.spawn(sources: sources, limit: limit) else {
            (parentOnly + [output.write, requests.write, replies.read]).forEach { close($0) }
            return nil
        }
        parentOnly.forEach { close($0) }
        // A helper that exited early must not turn a flush request into SIGPIPE here.
        _ = fcntl(requests.write, F_SETNOSIGPIPE, 1)
        self.pid = pid
        writeEnd = FileHandle(fileDescriptor: output.write, closeOnDealloc: false)
        control = requests.write
        acknowledgement = replies.read
        directory = log.url.deletingLastPathComponent()
        // The helper holds the log (and its lock) now; retention runs when it exits.
        log.close(pruning: false)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [self] in reap() }
        exitSource = source
        source.resume()
        reap()
    }

    private static func spawn(sources: [Int32], limit: Int) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        for (source, target) in zip(sources, [Int32(0), 1, 3, 4]) {
            posix_spawn_file_actions_adddup2(&actions, source, target)
        }
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        // Only the descriptors above reach the helper (never leases or other logs), and its
        // own process group keeps a terminal's Ctrl-C or the app's exit from stopping it.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP |
                                                     POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        let arguments = [helper, "-e", script, String(limit), truncationMarker(limit: limit)]
        let environment = ["PATH=/usr/bin:/bin", "LC_ALL=C"]
        var argv = arguments.map { strdup($0) } + [nil]
        var envp = environment.map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid = pid_t()
        let status = ProcessOutputCapture.descriptorLock.withLock {
            posix_spawn(&pid, helper, &actions, &attributes, &argv, &envp)
        }
        return status == 0 ? pid : nil
    }

    /// Waits (bounded) until the helper has written everything already in the pipe.
    func flush(timeout milliseconds: Int32 = 2_000) {
        lock.withLock {
            guard control >= 0, acknowledgement >= 0 else { return }
            var request = UInt8(ascii: "S")
            guard write(control, &request, 1) == 1 else { return }
            var reply = pollfd(fd: acknowledgement, events: Int16(POLLIN), revents: 0)
            let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(milliseconds) * 1_000_000
            while true {
                let left = Int64(deadline) - Int64(DispatchTime.now().uptimeNanoseconds)
                guard left > 0 else { return }
                let ready = poll(&reply, 1, Int32(left / 1_000_000) + 1)
                if ready < 0 && errno == EINTR { continue }
                break
            }
            if reply.revents & Int16(POLLIN) != 0 {
                var byte: UInt8 = 0
                _ = read(acknowledgement, &byte, 1)
            }
        }
    }

    /// Ends flush support; the helper keeps draining until the last writer exits.
    func detach() {
        lock.withLock {
            if control >= 0 { close(control); control = -1 }
            if acknowledgement >= 0 { close(acknowledgement); acknowledgement = -1 }
        }
    }

    private func reap() {
        let done: Bool = lock.withLock {
            guard !exited else { return false }
            var status: Int32 = 0
            guard waitpid(pid, &status, WNOHANG) == pid else { return false }
            exited = true
            exitSource?.cancel()
            exitSource = nil
            return true
        }
        if done { ProcessLogs.prune(directory: directory) }
    }

    deinit { detach() }
}
