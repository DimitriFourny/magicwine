import Darwin
import Foundation

/// One log of a bottle's operations or of the library (installs, inspections).
public struct ProcessLogEntry: Identifiable, Hashable, Sendable {
    public var id: URL { url }
    public let url: URL
    /// What produced the log: `launch`, `diagnostics`, `install`, `setup`, `winecfg`, `exec`,
    /// `wineserver` (a failed server probe), `stopped`, an installation step, or the
    /// operation part of an older flat log name.
    public let operation: String
    /// The program, installer, or command the operation ran, when there is one.
    public let detail: String?
    public let date: Date
    public let size: Int64
    /// Still held open by a running operation of any MagicWine process.
    public let isActive: Bool
}

/// Log layout and retention. Bottle logs live in `Logs/Bottles/<bottle-UUID>/` (backend
/// logs in its `dxvk`/`dxmt` subfolders), library logs in `Logs/Library/`. Names are
/// `<date time> <operation>[ <detail>].log`, created exclusively with mode 0600.
public enum ProcessLogs {
    public struct Retention: Sendable {
        public let maximumCount: Int
        public let maximumBytes: Int64
    }

    /// Each log folder (and each bottle's group of older flat logs) keeps at most its newest
    /// 50 logs within 256 MiB. The newest log and logs of running operations are always kept.
    public static let retention = Retention(maximumCount: 50, maximumBytes: 256 * 1_048_576)

    /// Output a single process may write to its log; the rest is discarded behind a marker.
    /// Debug builds accept `MAGICWINE_DEBUG_LOG_LIMIT` (bytes) to exercise truncation.
    public static let outputLimit: Int = {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["MAGICWINE_DEBUG_LOG_LIMIT"],
           let value = Int(text), value > 0 { return value }
        #endif
        return 64 * 1_048_576
    }()

    public static func bottleDirectory(_ id: UUID, paths: ApplicationPaths) -> URL {
        paths.logsDirectory.appendingPathComponent("Bottles", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public static func libraryDirectory(paths: ApplicationPaths) -> URL {
        paths.logsDirectory.appendingPathComponent("Library", isDirectory: true)
    }

    /// The bottle's logs, newest first, including older flat `Logs/<bottle-UUID>-*.log` files.
    public static func list(bottle id: UUID, paths: ApplicationPaths) -> [ProcessLogEntry] {
        let legacyPrefix = id.uuidString + "-"
        let files = entries(in: bottleDirectory(id, paths: paths)) +
            entries(in: paths.logsDirectory).filter { $0.url.lastPathComponent.hasPrefix(legacyPrefix) }
        return files.sorted { $0.date > $1.date }.map { file in
            let (operation, detail) = describe(file.url.deletingPathExtension().lastPathComponent)
            return ProcessLogEntry(url: file.url, operation: operation, detail: detail, date: file.date,
                                   size: file.size, isActive: isActive(file.url))
        }
    }

    /// Applies `retention` to every bottle folder, the library folder, and older flat logs
    /// (grouped per bottle, never moved). Missing folders are not created.
    public static func prune(paths: ApplicationPaths) {
        let bottles = paths.logsDirectory.appendingPathComponent("Bottles", isDirectory: true)
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: bottles.path)) ?? []
        where UUID(uuidString: folder) != nil {
            prune(directory: bottles.appendingPathComponent(folder, isDirectory: true))
        }
        prune(directory: libraryDirectory(paths: paths))
        let legacy = Dictionary(grouping: entries(in: paths.logsDirectory)) { file in
            UUID(uuidString: String(file.url.lastPathComponent.prefix(36))).map(\.uuidString)
        }
        for group in legacy.values { prune(group) }
    }

    /// Removes a deleted bottle's log folder and its older flat logs and backend folders.
    public static func removeLogs(forBottle id: UUID, paths: ApplicationPaths) throws {
        var targets = [bottleDirectory(id, paths: paths)]
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.logsDirectory.path)) ?? []
        targets += names.filter { $0.hasPrefix(id.uuidString + "-") }.map { paths.logsDirectory.appendingPathComponent($0) }
        for target in targets {
            var status = stat()
            guard lstat(target.path, &status) == 0 else { continue }
            // A link is removed itself; FileManager never follows links while removing.
            try FileManager.default.removeItem(at: target)
        }
    }

    static func prune(directory: URL) { prune(entries(in: directory)) }

    // MARK: Internals

    struct File {
        let url: URL
        let date: Date
        let size: Int64
        let device: dev_t
        let inode: ino_t
    }

    /// Ordinary `.log` files directly inside `directory`, never following links.
    static func entries(in directory: URL) -> [File] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".log") else { return nil }
            let url = directory.appendingPathComponent(name)
            var status = stat()
            guard lstat(url.path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
            let birth = status.st_birthtimespec
            return File(url: url, date: Date(timeIntervalSince1970: TimeInterval(birth.tv_sec) + TimeInterval(birth.tv_nsec) / 1e9),
                        size: Int64(status.st_size), device: status.st_dev, inode: status.st_ino)
        }
    }

    private static func prune(_ files: [File]) {
        var count = 0
        var bytes: Int64 = 0
        var full = false
        for file in files.sorted(by: { $0.date > $1.date }) {
            if !full, count < retention.maximumCount, count == 0 || bytes + file.size <= retention.maximumBytes {
                count += 1
                bytes += file.size
                continue
            }
            full = true
            if !removeIfInactive(file) {
                count += 1
                bytes += file.size
            }
        }
    }

    /// Unlinks only the same ordinary file, and only while no operation holds it open.
    private static func removeIfInactive(_ file: File) -> Bool {
        let descriptor = open(file.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        // Unlock explicitly: a child spawned on another thread can briefly share this
        // description, and close alone would keep the lock held until that child execs.
        defer {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_dev == file.device, status.st_ino == file.inode else { return false }
        return unlink(file.url.path) == 0
    }

    static func isActive(_ url: URL) -> Bool {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer {
            _ = flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
        }
        return flock(descriptor, LOCK_EX | LOCK_NB) != 0
    }

    static func name(operation: String, detail: String?, date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d.%02d.%02d.%03d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                           parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, (parts.nanosecond ?? 0) / 1_000_000)
        return [stamp, sanitize(operation), detail.map(sanitize)].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A file-name-safe, bounded form of a program or installer name.
    static func sanitize(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || "/:\\".unicodeScalars.contains(scalar) ? "-" : Character(scalar)
        }
        var result = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasPrefix(".") { result.removeFirst() }
        return String(result.prefix(60)).trimmingCharacters(in: .whitespaces)
    }

    /// Operation and detail from a current name, or the operation of an older flat name
    /// (`<bottle-UUID>-wine-<UUID>`, `wine-version-<UUID>`).
    static func describe(_ stem: String) -> (String, String?) {
        let stampLength = 23
        if stem.count > stampLength + 1, isStamp(stem.prefix(stampLength)) {
            var rest = String(stem.dropFirst(stampLength + 1))
            // An exclusive-name retry appends " (n)".
            if let range = rest.range(of: #" \(\d+\)$"#, options: .regularExpression) { rest.removeSubrange(range) }
            guard let space = rest.firstIndex(of: " ") else { return (rest, nil) }
            return (String(rest[..<space]), String(rest[rest.index(after: space)...]))
        }
        var legacy = stem
        if UUID(uuidString: String(legacy.prefix(36))) != nil, legacy.dropFirst(36).first == "-" { legacy = String(legacy.dropFirst(37)) }
        if legacy.count > 37, UUID(uuidString: String(legacy.suffix(36))) != nil { legacy = String(legacy.dropLast(37)) }
        return (legacy, nil)
    }

    private static func isStamp(_ text: Substring) -> Bool {
        let pattern = Array("dddd-dd-dd dd.dd.dd.ddd")
        return text.count == pattern.count && zip(text, pattern).allSatisfy { character, expected in
            expected == "d" ? character.isASCII && character.isNumber : character == expected
        }
    }
}

/// A newly and exclusively created log. While open it holds a shared `flock`, which
/// retention and the log list read as "still being written" in every MagicWine process
/// (a `ProcessLogDrain` helper holds its own description and lock of the same file).
/// Closing it unlocks explicitly and applies retention to its folder.
final class ProcessLogFile: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var storedDescriptor: Int32

    private init(url: URL, descriptor: Int32) {
        self.url = url
        storedDescriptor = descriptor
    }

    /// A separate append-only description of the same file with its own shared lock, for
    /// a writer in another process; nil when the file was replaced or cannot be locked.
    func openLockedDescription() -> Int32? {
        lock.withLock {
            guard storedDescriptor >= 0 else { return nil }
            let descriptor = open(url.path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { return nil }
            var own = stat(), opened = stat()
            guard fstat(storedDescriptor, &own) == 0, fstat(descriptor, &opened) == 0,
                  own.st_dev == opened.st_dev, own.st_ino == opened.st_ino,
                  flock(descriptor, LOCK_SH | LOCK_NB) == 0 else {
                Darwin.close(descriptor)
                return nil
            }
            return descriptor
        }
    }

    deinit { close() }

    static func create(in directory: URL, operation: String, detail: String? = nil) throws -> ProcessLogFile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw MagicWineError.unsafeFilesystem("The log folder must be an ordinary folder, not a symbolic link: \(directory.path)")
        }
        let base = ProcessLogs.name(operation: operation, detail: detail, date: Date())
        for attempt in 1...100 {
            let url = directory.appendingPathComponent(base + (attempt == 1 ? "" : " (\(attempt))") + ".log")
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if descriptor >= 0 {
                _ = flock(descriptor, LOCK_SH)
                return ProcessLogFile(url: url, descriptor: descriptor)
            }
            guard errno == EEXIST else { break }
        }
        throw MagicWineError.setup("Cannot create log: \(directory.appendingPathComponent(base).path).log: \(String(cString: strerror(errno))).")
    }

    /// Creates, writes, and closes a complete log.
    static func record(_ contents: Data, in directory: URL, operation: String, detail: String? = nil) throws -> URL {
        let file = try create(in: directory, operation: operation, detail: detail)
        file.write(contents)
        file.close()
        return file.url
    }

    func write(_ data: Data) { data.withUnsafeBytes { write($0) } }

    /// Best effort: a full disk must never block or fail the process being logged.
    func write(_ bytes: UnsafeRawBufferPointer) {
        lock.withLock {
            guard storedDescriptor >= 0, let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(storedDescriptor, base + offset, bytes.count - offset)
                if written > 0 { offset += written }
                else if written < 0 && errno == EINTR { continue }
                else { return }
            }
        }
    }

    /// `pruning: false` when another process (a drain helper) keeps writing the log.
    func close(pruning: Bool = true) {
        let closed: Bool = lock.withLock {
            guard storedDescriptor >= 0 else { return false }
            // Unlock explicitly: a child spawned on another thread can briefly share this
            // description, and close alone would keep the log "running" until it execs.
            _ = flock(storedDescriptor, LOCK_UN)
            Darwin.close(storedDescriptor)
            storedDescriptor = -1
            return true
        }
        if closed && pruning { ProcessLogs.prune(directory: url.deletingLastPathComponent()) }
    }
}
