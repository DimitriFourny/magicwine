import Darwin
import Foundation

/// One line of a process log, classified by Wine's debug class (`err:`, `warn:`,
/// `fixme:`, optionally after a thread ID such as `0024:`).
public struct ProcessLogLine: Hashable, Sendable {
    public enum Level: CaseIterable, Sendable {
        case error, warning, fixme, other
    }

    public let text: String
    public let level: Level

    public init(_ text: String) {
        self.text = text
        level = Self.level(of: text)
    }

    /// The same rule `ProcessLogSummary` uses for errors.
    public static func level(of text: String) -> Level {
        let line = text.drop { $0 == " " || $0 == "\t" }
        func has(_ tag: String) -> Bool { line.hasPrefix(tag + ":") || line.contains(":" + tag + ":") }
        if has("err") { return .error }
        if has("warn") { return .warning }
        if has("fixme") { return .fixme }
        return .other
    }
}

/// Follows a log with bounded memory: the first read returns at most the last `window`
/// bytes, later reads only what was appended. A file that was replaced or shrank, or more
/// new output than `window` between two reads, restarts from the end (`reset`).
public struct ProcessLogTail: Sendable {
    public struct Update: Sendable {
        public let lines: [ProcessLogLine]
        /// Previously returned lines no longer precede these; replace them.
        public let reset: Bool
        /// Output before these lines was skipped to stay within the window.
        public let omittedEarlier: Bool
        /// A running operation of any MagicWine process still writes the log.
        public let isActive: Bool
    }

    public static let defaultWindow = 4 * 1_048_576
    /// A line longer than this is split rather than buffered indefinitely.
    static let lineLimit = 64 * 1_024

    public let url: URL
    private let window: Int
    private var identity: (dev_t, ino_t)?
    private var offset: Int64 = 0
    private var pending = Data()

    public init(url: URL, window: Int = ProcessLogTail.defaultWindow) {
        self.url = url
        self.window = max(1, window)
    }

    public mutating func read() throws -> Update {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MagicWineError.setup("Cannot open the log \(url.path): \(String(cString: strerror(errno))).")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw MagicWineError.unsafeFilesystem("The log is not an ordinary file: \(url.path)")
        }
        var reset = false
        if identity.map({ $0.0 != status.st_dev || $0.1 != status.st_ino }) ?? true || Int64(status.st_size) < offset {
            reset = identity != nil
            identity = (status.st_dev, status.st_ino)
            offset = 0
            pending.removeAll()
        }
        var start = offset
        var omitted = false
        if Int64(status.st_size) - start > Int64(window) {
            start = Int64(status.st_size) - Int64(window)
            omitted = true
            reset = reset || offset > 0
            pending.removeAll()
        }
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: Int(Int64(status.st_size) - start)) ?? Data()
        offset = start + Int64(data.count)
        var bytes = pending + data
        pending.removeAll()
        // A skip lands inside a line; never show that fragment.
        if omitted, start > 0 {
            bytes = bytes.firstIndex(of: 0x0A).map { Data(bytes[bytes.index(after: $0)...]) } ?? Data()
        }
        let active = ProcessLogs.isActive(url)
        var complete = bytes
        if let lastNewline = bytes.lastIndex(of: 0x0A) {
            complete = Data(bytes[...lastNewline])
            pending = Data(bytes[bytes.index(after: lastNewline)...])
        } else {
            complete = Data()
            pending = bytes
        }
        // A finished log or an overlong line has no further text to wait for.
        if !active || pending.count > Self.lineLimit {
            complete.append(pending)
            pending.removeAll()
        }
        let lines = String(decoding: complete, as: UTF8.self)
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let trimmed = lines.last?.isEmpty == true ? lines.dropLast() : lines[...]
        return Update(lines: trimmed.map { ProcessLogLine(String($0)) }, reset: reset,
                      omittedEarlier: omitted, isActive: active)
    }
}
