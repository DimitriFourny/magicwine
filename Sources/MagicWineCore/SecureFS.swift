import CryptoKit
import Darwin
import Foundation

/// Shared no-follow filesystem checks for installers and compatibility code.
/// Every path is inspected with `lstat` or opened with `O_NOFOLLOW`; symbolic
/// links are never traversed. Size limits, hard-link tolerance and the message
/// prefix stay explicit at each call site, so components keep their own policy.
struct SecureFS: Sendable {
    let prefix: String

    init(prefix: String) { self.prefix = prefix }

    /// A filesystem safety refusal: links, unexpected file types or occupied destinations.
    func failure(_ message: String) -> MagicWineError { .unsafeFilesystem(prefix + message) }

    /// Content that is malformed, oversized, changed while read, or does not match its pin.
    func integrity(_ message: String) -> MagicWineError { .integrityFailure(prefix + message) }

    /// Captures `errno` immediately: call before any other system call.
    func posixFailure(_ operation: String, _ url: URL) -> MagicWineError {
        let code = errno
        return failure("Cannot \(operation) \(url.path): \(String(cString: strerror(code))).")
    }

    func directoryFailure(_ url: URL) -> MagicWineError {
        failure("Expected an ordinary directory, not a symbolic link or file: \(url.path).")
    }

    // MARK: lstat

    /// `lstat` without following a final symbolic link; nil only when absent.
    func statusIfPresent(_ url: URL) throws -> stat? {
        guard url.isFileURL else { throw failure("Only local filesystem paths are accepted: \(url.absoluteString).") }
        var status = stat()
        if url.path.withCString({ lstat($0, &status) }) == 0 { return status }
        if errno == ENOENT { return nil }
        throw posixFailure("inspect", url)
    }

    func status(_ url: URL) throws -> stat {
        guard let status = try statusIfPresent(url) else {
            throw failure("Cannot inspect \(url.path): \(String(cString: strerror(ENOENT))).")
        }
        return status
    }

    func exists(_ url: URL) throws -> Bool { try statusIfPresent(url) != nil }
    func fileType(_ url: URL) throws -> mode_t { try status(url).st_mode & mode_t(S_IFMT) }
    func fileTypeIfPresent(_ url: URL) throws -> mode_t? { try statusIfPresent(url).map { $0.st_mode & mode_t(S_IFMT) } }

    func requireDirectory(_ url: URL) throws {
        guard try fileType(url) == mode_t(S_IFDIR) else { throw directoryFailure(url) }
    }

    /// A nonempty regular file within `maximum` bytes and, unless allowed, without hard links.
    @discardableResult
    func requireFile(_ url: URL, maximum: Int, allowsHardLinks: Bool = false) throws -> stat {
        let status = try status(url)
        guard Self.isRegularFile(status, maximum: maximum, allowsHardLinks: allowsHardLinks) else {
            throw fileFailure(url, maximum: maximum, allowsHardLinks: allowsHardLinks)
        }
        return status
    }

    // MARK: Bounded reads

    /// Opens without following links and rechecks the opened descriptor, so a
    /// path swapped after an earlier `lstat` cannot substitute another file.
    func open(_ url: URL, maximum: Int, allowsHardLinks: Bool = false) throws -> (handle: FileHandle, status: stat) {
        guard url.isFileURL else { throw failure("Only local filesystem paths are accepted: \(url.absoluteString).") }
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw posixFailure("open without following links", url) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              Self.isRegularFile(status, maximum: maximum, allowsHardLinks: allowsHardLinks) else {
            try? handle.close()
            throw fileFailure(url, maximum: maximum, allowsHardLinks: allowsHardLinks)
        }
        return (handle, status)
    }

    /// Streaming SHA-256 bounded by `maximum`. The file must still be the same
    /// unchanged inode afterwards; cancellation is checked between chunks.
    func sha256(_ url: URL, maximum: Int, allowsHardLinks: Bool = false) throws -> String {
        var digest = SHA256()
        try stream(url, maximum: maximum, allowsHardLinks: allowsHardLinks) { digest.update(data: $0) }
        return Self.hex(digest.finalize())
    }

    /// The complete contents, with the same bounds and stability checks as `sha256`.
    func read(_ url: URL, maximum: Int, allowsHardLinks: Bool = false) throws -> Data {
        var data = Data()
        try stream(url, maximum: maximum, allowsHardLinks: allowsHardLinks) { data.append($0) }
        return data
    }

    private func stream(_ url: URL, maximum: Int, allowsHardLinks: Bool, _ body: (Data) throws -> Void) throws {
        let (handle, before) = try open(url, maximum: maximum, allowsHardLinks: allowsHardLinks)
        defer { try? handle.close() }
        var count = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation()
            count += chunk.count
            guard count <= maximum else {
                throw integrity("File exceeds its \(Self.describe(maximum)) safety limit: \(url.path).")
            }
            try body(chunk)
        }
        // Hard-linked files may legitimately gain links (changing ctime) while
        // read; their identity, size and modification time must still match.
        guard let after = try statusIfPresent(url), count == before.st_size,
              Self.isRegularFile(after, maximum: maximum, allowsHardLinks: allowsHardLinks),
              allowsHardLinks ? Stamp(after).sameContent(as: Stamp(before)) : Stamp(after) == Stamp(before) else {
            throw integrity("File changed during validation: \(url.path).")
        }
    }

    // MARK: Validation evidence

    /// Inode identity plus size and modification/change times of an `lstat` result.
    struct Stamp: Equatable, Codable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = status.st_ctimespec.tv_nsec
        }

        func sameContent(as other: Stamp) -> Bool {
            device == other.device && inode == other.inode && size == other.size &&
                modifiedSeconds == other.modifiedSeconds && modifiedNanoseconds == other.modifiedNanoseconds
        }
    }

    /// Stamps of `names` relative to `root`; the empty name stamps `root` itself.
    func stamps(at root: URL, names: [String]) throws -> [String: Stamp] {
        var result: [String: Stamp] = [:]
        for name in names { result[name] = Stamp(try status(name.isEmpty ? root : root.appendingPathComponent(name))) }
        return result
    }

    /// Process-local adoption cache, never persisted as evidence of integrity. The
    /// first adoption hashes every file; inode/size/mtime/ctime changes invalidate it.
    final class ValidationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [String: Stamp]] = [:]

        /// Runs `verify` unless `root`'s stamps for `names` match the last successful
        /// verification (or `rehash` is set), then requires the stamps to be unchanged.
        func verify(_ root: URL, names: [String], fs: SecureFS, rehash: Bool,
                    changed: @autoclosure () -> MagicWineError, _ verify: () throws -> Void) throws {
            let before = try fs.stamps(at: root, names: names)
            if !rehash, lock.withLock({ entries[root.path] == before }) { return }
            try verify()
            let after = try fs.stamps(at: root, names: Array(before.keys))
            guard before == after else { throw changed() }
            lock.withLock { entries[root.path] = after }
        }
    }

    // MARK: Publication

    /// Atomically renames `source` to `destination` only if nothing exists there
    /// (`renamex_np(RENAME_EXCL)`). Returns false, leaving both untouched, when the
    /// destination is already occupied; the caller decides whether to adopt it.
    func publish(_ source: URL, to destination: URL) throws -> Bool {
        let result = source.path.withCString { from in
            destination.path.withCString { renamex_np(from, $0, UInt32(RENAME_EXCL)) }
        }
        if result == 0 { return true }
        let code = errno
        if code == EEXIST || code == ENOTEMPTY { return false }
        throw failure("Cannot atomically publish \(destination.path); existing files were left untouched: \(String(cString: strerror(code))).")
    }

    /// Copies `com.apple.quarantine` (if any) from `source` to `target` without
    /// following links. Quarantine is preserved, never removed or invented.
    func preserveQuarantine(from source: URL, to target: URL) throws {
        let name = "com.apple.quarantine"
        let size = source.path.withCString { getxattr($0, name, nil, 0, 0, XATTR_NOFOLLOW) }
        if size < 0 {
            guard errno == ENOATTR else { throw posixFailure("inspect quarantine on", source) }
            return
        }
        guard size <= 65_536 else { throw failure("Quarantine metadata exceeds its safety limit: \(source.path).") }
        var data = Data(count: size)
        let received = data.withUnsafeMutableBytes { bytes in
            source.path.withCString { getxattr($0, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
        }
        guard received == size else { throw posixFailure("read quarantine on", source) }
        let result = data.withUnsafeBytes { bytes in
            target.path.withCString { setxattr($0, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
        }
        guard result == 0 else { throw posixFailure("preserve quarantine on", target) }
    }

    // MARK: Helpers

    static func digest(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isRegularFile(_ status: stat, maximum: Int, allowsHardLinks: Bool) -> Bool {
        status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && (allowsHardLinks || status.st_nlink == 1) &&
            status.st_size > 0 && status.st_size <= Int64(maximum)
    }

    private func fileFailure(_ url: URL, maximum: Int, allowsHardLinks: Bool) -> MagicWineError {
        failure("Expected a nonempty ordinary file without symbolic\(allowsHardLinks ? "" : " or hard") links, within its \(Self.describe(maximum)) safety limit: \(url.path).")
    }

    private static func describe(_ bytes: Int) -> String {
        bytes % 1_048_576 == 0 ? "\(bytes / 1_048_576) MiB" : "\(bytes)-byte"
    }
}
