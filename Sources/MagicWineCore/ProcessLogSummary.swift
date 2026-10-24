import Darwin
import Foundation

/// A short, bounded excerpt of a process log for status messages. A log can hold up to
/// `ProcessLogs.outputLimit` of output, so only the tail is read. When a log was truncated
/// at that limit, its tail is the output just before the truncation marker: errors the
/// process printed after the limit were discarded and cannot appear here.
public enum ProcessLogSummary {
    public static let tailBytes = 64 * 1_024
    static let lineLimit = 240

    /// The last few Wine `err:` lines near the end of the log, or nil when the log is
    /// missing, unreadable, not an ordinary file, or reports no such lines.
    public static func summary(at url: URL, maximumLines: Int = 3) -> String? {
        guard maximumLines > 0, url.isFileURL else { return nil }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        // Read one byte before the tail to know whether it starts at a line boundary.
        let offset = UInt64(max(0, Int64(status.st_size) - Int64(tailBytes) - 1))
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: tailBytes + 1) else { return nil }
        // Windows programs often write CRLF, which Swift treats as one Character.
        var lines = String(decoding: data, as: UTF8.self).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        // A tail read usually starts inside a line; never report that fragment.
        if offset > 0, !lines.isEmpty { lines.removeFirst() }
        let errors = lines.lazy.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("err:") || $0.contains(":err:") }
        let selected = Array(errors).suffix(maximumLines).map { line in
            line.count > lineLimit ? String(line.prefix(lineLimit - 1)) + "…" : line
        }
        return selected.isEmpty ? nil : selected.joined(separator: "\n")
    }
}
