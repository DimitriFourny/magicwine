import CryptoKit
import Darwin
import Foundation

/// Prefix changes and their metadata commit share a cross-process lock. The journal is
/// published before any DLL is touched; recovery chooses solely by the atomic metadata commit.
internal enum GraphicsPrefix {
    /// The DXVK footprint; the first four entries are the historical four-DLL DXVK ABI
    /// of legacy manifests and journals. Never reorder them.
    static let dllPaths = [
        "drive_c/windows/system32/d3d10core.dll", "drive_c/windows/system32/d3d11.dll",
        "drive_c/windows/syswow64/d3d10core.dll", "drive_c/windows/syswow64/d3d11.dll",
        "drive_c/windows/system32/d3d9.dll", "drive_c/windows/syswow64/d3d9.dll"
    ]
    private static let legacyDLLCount = 4
    private static let schema = 2
    private static var manager: FileManager { FileManager.default }
    private static let fs = SecureFS(prefix: "Graphics setup: ")

    private static func mappings(for backend: GraphicsBackend) -> [GraphicsPrefixMapping] {
        backend.componentProvider?.prefixMappings ?? []
    }

    private static let allowedPaths = Set(GraphicsBackend.allCases.flatMap { mappings(for: $0).map(\.destination) })

    private static func union(_ previous: [String], _ next: [String]) -> [String] {
        previous + next.filter { !previous.contains($0) }
    }

    private struct Entry: Codable {
        let originalExists: Bool
        let installedHash: String
        let installedSize: UInt64
    }

    private struct Manifest: Codable {
        let schema: Int?
        let backend: GraphicsBackend?
        let paths: [String]?
        let componentID: String
        let entries: [Entry]

        var resolvedBackend: GraphicsBackend { backend ?? .dxvk }
        var resolvedPaths: [String] { paths ?? Array(dllPaths.prefix(entries.count)) }
    }

    private struct Snapshot: Codable {
        let exists: Bool
        let fingerprint: String?
    }

    private struct Journal: Codable {
        let schema: Int?
        let paths: [String]?
        let previousPaths: [String]?
        let nextPaths: [String]?
        let previousMetadata: Data
        let nextMetadata: Data
        let before: [Snapshot]
        let after: [Snapshot]
        let hadActive: Bool
        let hasActive: Bool
        let displaced: [Bool]

        var resolvedPaths: [String] { paths ?? Array(dllPaths.prefix(before.count)) }
    }

    /// Runs `body`, a synchronous critical section, while holding the bottle's exclusive
    /// metadata and prefix lock. Waiting never parks an executor thread and honors
    /// cancellation; a lock still held by another operation after `timeout` is `busy`.
    /// `body` runs on the caller's actor.
    static func withLock<T>(bottleDirectory: URL, timeout: Duration = .seconds(30),
                            isolation: isolated (any Actor)? = #isolation,
                            _ body: () throws -> T) async throws -> T {
        let locks = bottleDirectory.deletingLastPathComponent().appendingPathComponent(".graphics-locks", isDirectory: true)
        try ensureDirectory(locks, create: true)
        let url = locks.appendingPathComponent(bottleDirectory.lastPathComponent + ".lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw fileError("Cannot open the bottle graphics lock") }
        // Unlock explicitly: a child forked by another thread can briefly share this
        // descriptor until it execs, and close alone would keep the lock held meanwhile.
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard try await AdvisoryFileLock.acquire(descriptor, exclusive: true, timeout: timeout) else {
            throw MagicWineError.busy("Another MagicWine operation is still changing this bottle; nothing was changed by this one.",
                                      reason: .operationInProgress)
        }
        return try body()
    }

    /// Must be called while holding withLock, including for ordinary fresh metadata reads.
    static func recover(bottleDirectory: URL) throws {
        let graphics = bottleDirectory.appendingPathComponent("graphics", isDirectory: true)
        guard try fs.exists(graphics) else { return }
        try ensureDirectory(graphics)
        let transaction = graphics.appendingPathComponent("transaction", isDirectory: true)
        guard try fs.exists(transaction) else { return }
        try ensureDirectory(transaction)
        let journalURL = transaction.appendingPathComponent("journal.json")
        guard try fs.exists(journalURL) else {
            // Preparation never modifies the prefix before the journal is published.
            try manager.removeItem(at: transaction)
            return
        }
        let journal = try readJournal(journalURL)
        let metadataURL = bottleDirectory.appendingPathComponent("bottle.json")
        try requireRegularFile(metadataURL)
        let metadata = try Data(contentsOf: metadataURL)
        if metadata == journal.nextMetadata {
            try manager.removeItem(at: transaction)
            return
        }
        guard metadata == journal.previousMetadata else {
            throw MagicWineError.integrityFailure("Bottle metadata changed during an interrupted graphics transaction. Its recovery files have been retained.")
        }
        let prefix = bottleDirectory.appendingPathComponent("prefix", isDirectory: true)
        try validateDestinations(prefix: prefix, paths: journal.resolvedPaths)
        try restoreSnapshot(journal: journal, transaction: transaction, graphics: graphics, prefix: prefix)
        try manager.removeItem(at: transaction)
    }

    /// Runtime launch checks are deliberately inexpensive. Source hashes are validated at
    /// setup; restoration uses the saved installed hashes to recognize user replacements.
    static func validateInstalled(configuration: GraphicsConfiguration, prefix: URL, bottleDirectory: URL) throws {
        guard configuration.backend != .standard else { return }
        let paths = mappings(for: configuration.backend).map(\.destination)
        try validateDestinations(prefix: prefix, paths: paths)
        let active = bottleDirectory.appendingPathComponent("graphics/active", isDirectory: true)
        let manifest = try readManifest(active)
        guard manifest.componentID == configuration.componentID,
              manifest.resolvedBackend == configuration.backend, manifest.resolvedPaths == paths else {
            throw MagicWineError.componentInvalid("The bottle's graphics installation does not match its selected component.")
        }
        for (index, path) in paths.enumerated() {
            let file = prefix.appendingPathComponent(path)
            try requireRegularFile(file)
            let attributes = try manager.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.uint64Value == manifest.entries[index].installedSize else {
                throw MagicWineError.componentInvalid("The bottle's graphics DLLs are missing or changed.")
            }
        }
    }

    /// Caller holds the lock and has freshly validated owned, initialized metadata.
    /// The closure is the sole atomic metadata write and is executed after all file changes.
    /// `componentUpdate` permits replacing the selected backend's component in place: the
    /// same journaled transaction swaps its DLLs while keeping the pre-renderer originals.
    static func change(from previous: GraphicsConfiguration, to next: GraphicsConfiguration,
                       componentRoot: URL?, bottleDirectory: URL, previousMetadata: Data,
                       nextMetadata: Data, componentUpdate: Bool = false, commit: () throws -> Void) throws {
        if previous.backend == next.backend && previous.componentID == next.componentID {
            // In particular, a HUD-only change never reinstalls or captures managed DLLs
            // as originals. Standard reads/changes need not create a graphics directory.
            try commit()
            return
        }
        let transaction = try prepare(from: previous, to: next, componentRoot: componentRoot,
                                      bottleDirectory: bottleDirectory, previousMetadata: previousMetadata,
                                      nextMetadata: nextMetadata, componentUpdate: componentUpdate)
        do {
            try apply(transaction: transaction, bottleDirectory: bottleDirectory)
            try commit()
        } catch {
            do { try recover(bottleDirectory: bottleDirectory) }
            catch let recoveryError {
                throw MagicWineError.setup("Graphics setup failed (\(error.localizedDescription)); recovery must finish before this bottle can launch (\(recoveryError.localizedDescription)).")
            }
            throw error
        }
        // A cleanup failure cannot roll back a committed selection. The next locked read
        // sees the committed metadata and completes cleanup without touching the DLLs.
        try? manager.removeItem(at: transaction)
    }

    /// Separate preparation/application allows recovery of a process killed at any point.
    /// These internal operations always require the same bottle lock as change/recover.
    static func prepare(from previous: GraphicsConfiguration, to next: GraphicsConfiguration,
                        componentRoot: URL?, bottleDirectory: URL, previousMetadata: Data,
                        nextMetadata: Data, componentUpdate: Bool = false) throws -> URL {
        guard previous.backend == .standard || previous.backend != next.backend ||
                (componentUpdate && previous.componentID != next.componentID) else {
            throw MagicWineError.componentInvalid("Changing this bottle's graphics component requires an explicit component update.")
        }
        let prefix = bottleDirectory.appendingPathComponent("prefix", isDirectory: true)
        let graphics = bottleDirectory.appendingPathComponent("graphics", isDirectory: true)
        let active = graphics.appendingPathComponent("active", isDirectory: true)
        let incoming = mappings(for: next.backend)
        try validateDestinations(prefix: prefix, paths: incoming.map(\.destination))
        if try fs.exists(graphics) { try ensureDirectory(graphics) }
        let oldManifest: Manifest?
        if previous.backend != .standard {
            let manifest = try readManifest(active)
            guard manifest.componentID == previous.componentID, manifest.resolvedBackend == previous.backend else {
                throw MagicWineError.integrityFailure("The bottle's graphics backup does not match its selected component.")
            }
            oldManifest = manifest
        } else {
            guard try !fs.exists(active) else { throw MagicWineError.unsafeFilesystem("The bottle has an unexpected graphics backup; refusing to overwrite it.") }
            oldManifest = nil
        }
        let previousPaths = oldManifest?.resolvedPaths ?? []
        let nextPaths = incoming.map(\.destination)
        let paths = union(previousPaths, nextPaths)
        try validateDestinations(prefix: prefix, paths: paths)
        if next.backend != .standard {
            guard let componentRoot, let id = next.componentID, validComponentID(id) else {
                throw MagicWineError.invalidInput("This renderer requires an installed graphics component.")
            }
            try ensureDirectory(componentRoot)
            for mapping in incoming {
                var parent = componentRoot
                for part in mapping.source.split(separator: "/").dropLast() {
                    parent.appendPathComponent(String(part))
                    try ensureDirectory(parent)
                }
                try requireRegularFile(componentRoot.appendingPathComponent(mapping.source))
            }
        }
        try ensureDirectory(graphics, create: true)
        let transaction = graphics.appendingPathComponent("transaction", isDirectory: true)
        guard try !fs.exists(transaction) else { throw MagicWineError.conflict("A graphics transaction must be recovered before setup.") }
        try ensureDirectory(transaction, create: true)
        do {
            let beforeDirectory = transaction.appendingPathComponent("before", isDirectory: true)
            let afterDirectory = transaction.appendingPathComponent("after", isDirectory: true)
            try ensureDirectory(beforeDirectory, create: true)
            try ensureDirectory(afterDirectory, create: true)
            if oldManifest != nil {
                try manager.copyItem(at: active, to: transaction.appendingPathComponent("before-active"))
            }
            let nextActive = transaction.appendingPathComponent("after-active", isDirectory: true)
            if next.backend != .standard {
                try ensureDirectory(nextActive, create: true)
                try ensureDirectory(nextActive.appendingPathComponent("originals"), create: true)
            }
            var before: [Snapshot] = []
            var after: [Snapshot] = []
            var entries: [String: Entry] = [:]
            var displaced: [Bool] = []
            for (index, path) in paths.enumerated() {
                let destination = prefix.appendingPathComponent(path)
                let beforeSnapshot = try snapshot(destination)
                before.append(beforeSnapshot)
                if beforeSnapshot.exists { try manager.copyItem(at: destination, to: beforeDirectory.appendingPathComponent(String(index))) }
                let oldIndex = previousPaths.firstIndex(of: path)
                let oldEntry = oldIndex.flatMap { oldManifest?.entries[$0] }
                displaced.append(oldEntry != nil && beforeSnapshot.exists && beforeSnapshot.fingerprint != "file:" + oldEntry!.installedHash)
                // Overlap carries the pre-renderer original, not the outgoing renderer.
                // Incoming-only paths capture their current file/link/absence instead.
                let originalExists = oldEntry?.originalExists ?? beforeSnapshot.exists
                let original = oldIndex.map { active.appendingPathComponent("originals/\($0)") } ?? destination
                if originalExists { try requireFileOrLink(original) }
                let staged = afterDirectory.appendingPathComponent(String(index))
                if let nextIndex = nextPaths.firstIndex(of: path) {
                    if originalExists { try manager.copyItem(at: original, to: nextActive.appendingPathComponent("originals/\(nextIndex)")) }
                    let source = componentRoot!.appendingPathComponent(incoming[nextIndex].source)
                    try manager.copyItem(at: source, to: staged)
                    let digest = try hash(staged)
                    entries[path] = Entry(originalExists: originalExists, installedHash: digest.hex, installedSize: digest.size)
                    after.append(Snapshot(exists: true, fingerprint: "file:" + digest.hex))
                } else {
                    // Outgoing-only paths are restored in this same transaction.
                    if originalExists { try manager.copyItem(at: original, to: staged) }
                    after.append(try snapshot(staged))
                }
            }
            if next.backend != .standard {
                let manifest = Manifest(schema: schema, backend: next.backend, paths: nextPaths,
                                        componentID: next.componentID!, entries: nextPaths.map { entries[$0]! })
                try JSONEncoder().encode(manifest).write(to: nextActive.appendingPathComponent("manifest.json"), options: .atomic)
            }
            let journal = Journal(schema: schema, paths: paths, previousPaths: previousPaths, nextPaths: nextPaths,
                                  previousMetadata: previousMetadata, nextMetadata: nextMetadata, before: before,
                                  after: after, hadActive: oldManifest != nil, hasActive: next.backend != .standard,
                                  displaced: displaced)
            try JSONEncoder().encode(journal).write(to: transaction.appendingPathComponent("journal.json"), options: .atomic)
            return transaction
        } catch {
            try? manager.removeItem(at: transaction)
            throw error
        }
    }

    static func apply(transaction: URL, bottleDirectory: URL) throws {
        let graphics = bottleDirectory.appendingPathComponent("graphics", isDirectory: true)
        let prefix = bottleDirectory.appendingPathComponent("prefix", isDirectory: true)
        try ensureDirectory(graphics)
        try ensureDirectory(transaction)
        let journal = try readJournal(transaction.appendingPathComponent("journal.json"))
        try validateDestinations(prefix: prefix, paths: journal.resolvedPaths)
        // A malformed or incomplete staged payload must fail before the first deletion.
        try validateActiveBackup(journal: journal, transaction: transaction, after: false)
        try validateActiveBackup(journal: journal, transaction: transaction, after: true)
        try validateSnapshots(journal.before, directory: transaction.appendingPathComponent("before"))
        try validateSnapshots(journal.after, directory: transaction.appendingPathComponent("after"))
        for (index, path) in journal.resolvedPaths.enumerated() {
            let destination = prefix.appendingPathComponent(path)
            let current = try snapshot(destination)
            if current.exists,
               journal.displaced[index] || (current.fingerprint != journal.before[index].fingerprint &&
                                             current.fingerprint != journal.after[index].fingerprint) {
                try preserve(destination, path: path, graphics: graphics)
            }
            try replace(destination, with: transaction.appendingPathComponent("after/\(index)"), exists: journal.after[index].exists)
        }
        try replace(graphics.appendingPathComponent("active"), with: transaction.appendingPathComponent("after-active"), exists: journal.hasActive)
    }

    private static func restoreSnapshot(journal: Journal, transaction: URL, graphics: URL, prefix: URL) throws {
        try validateActiveBackup(journal: journal, transaction: transaction, after: false)
        // The old active footprint is a subset of the union journal when renderers differ.
        // Recovery deliberately does not depend on an intact, possibly failed after stage.
        try validateSnapshots(journal.before, directory: transaction.appendingPathComponent("before"))
        for (index, path) in journal.resolvedPaths.enumerated() {
            let destination = prefix.appendingPathComponent(path)
            let current = try snapshot(destination)
            if current.exists, current.fingerprint != journal.before[index].fingerprint,
               current.fingerprint != journal.after[index].fingerprint {
                try preserve(destination, path: path, graphics: graphics)
            }
            try replace(destination, with: transaction.appendingPathComponent("before/\(index)"), exists: journal.before[index].exists)
        }
        try replace(graphics.appendingPathComponent("active"), with: transaction.appendingPathComponent("before-active"), exists: journal.hadActive)
    }

    private static func readJournal(_ url: URL) throws -> Journal {
        try requireRegularFile(url)
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
        let count = journal.before.count
        guard journal.after.count == count, journal.displaced.count == count,
              journal.before.allSatisfy(validSnapshot), journal.after.allSatisfy(validSnapshot),
              journal.previousMetadata != journal.nextMetadata else {
            throw MagicWineError.integrityFailure("The bottle graphics recovery journal is invalid.")
        }
        let previous = try JSONDecoder().decode(Bottle.self, from: journal.previousMetadata).graphics
        let next = try JSONDecoder().decode(Bottle.self, from: journal.nextMetadata).graphics
        // A same-backend journal is an in-place component update of a non-Standard backend.
        guard previous.backend != next.backend ||
                (previous.backend != .standard && previous.componentID != next.componentID),
              journal.hadActive == (previous.backend != .standard),
              journal.hasActive == (next.backend != .standard) else {
            throw MagicWineError.integrityFailure("The bottle graphics recovery journal has inconsistent selections.")
        }
        if let version = journal.schema {
            guard version == schema, let paths = journal.paths,
                  let previousPaths = journal.previousPaths, let nextPaths = journal.nextPaths,
                  validPaths(paths), paths.count == count,
                  validFootprint(previousPaths, backend: previous.backend, allowLegacy: true),
                  validFootprint(nextPaths, backend: next.backend, allowLegacy: false),
                  paths == union(previousPaths, nextPaths) else {
                throw MagicWineError.integrityFailure("The bottle graphics recovery journal has invalid DLL paths.")
            }
        } else {
            guard journal.paths == nil, journal.previousPaths == nil, journal.nextPaths == nil,
                  count == legacyDLLCount || count == dllPaths.count,
                  [previous.backend, next.backend].allSatisfy({ $0 == .standard || $0 == .dxvk }) else {
                throw MagicWineError.integrityFailure("The bottle graphics legacy recovery journal is invalid.")
            }
        }
        return journal
    }

    private static func readManifest(_ active: URL) throws -> Manifest {
        try ensureDirectory(active.deletingLastPathComponent())
        try ensureDirectory(active)
        let url = active.appendingPathComponent("manifest.json")
        try requireRegularFile(url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard validComponentID(manifest.componentID),
              manifest.entries.allSatisfy({ validHash($0.installedHash) && $0.installedSize > 0 }) else {
            throw MagicWineError.integrityFailure("The bottle graphics backup is invalid.")
        }
        if let version = manifest.schema {
            guard version == schema, let backend = manifest.backend, backend != .standard,
                  let paths = manifest.paths, validPaths(paths), paths.count == manifest.entries.count,
                  validFootprint(paths, backend: backend, allowLegacy: false) else {
                throw MagicWineError.integrityFailure("The bottle graphics backup has invalid DLL paths.")
            }
        } else {
            guard manifest.backend == nil, manifest.paths == nil,
                  manifest.entries.count == legacyDLLCount || manifest.entries.count == dllPaths.count else {
                throw MagicWineError.integrityFailure("The bottle graphics legacy backup is invalid.")
            }
        }
        try ensureDirectory(active.appendingPathComponent("originals"))
        for index in manifest.entries.indices {
            let original = active.appendingPathComponent("originals/\(index)")
            if manifest.entries[index].originalExists {
                try requireFileOrLink(original)
            } else if try fs.exists(original) {
                throw MagicWineError.integrityFailure("The bottle graphics backup contains an unexpected original DLL.")
            }
        }
        return manifest
    }

    private static func validPaths(_ paths: [String]) -> Bool {
        !paths.isEmpty && Set(paths).count == paths.count && paths.allSatisfy { allowedPaths.contains($0) }
    }

    private static func validFootprint(_ paths: [String], backend: GraphicsBackend, allowLegacy: Bool) -> Bool {
        let expected = mappings(for: backend)
        return (paths.count == expected.count && zip(paths, expected).allSatisfy { $0.0 == $0.1.destination }) ||
            (allowLegacy && backend == .dxvk && paths.elementsEqual(dllPaths.prefix(legacyDLLCount)))
    }

    private static func validComponentID(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") &&
            !value.contains("\\") && !value.utf8.contains(0)
    }

    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func validSnapshot(_ value: Snapshot) -> Bool {
        guard value.exists else { return value.fingerprint == nil }
        guard let fingerprint = value.fingerprint else { return false }
        if fingerprint.hasPrefix("file:") { return validHash(String(fingerprint.dropFirst(5))) }
        return fingerprint.hasPrefix("link:") && fingerprint.count > 5 && !fingerprint.utf8.contains(0)
    }

    private static func validateSnapshots(_ snapshots: [Snapshot], directory: URL) throws {
        try ensureDirectory(directory)
        for index in snapshots.indices {
            let saved = try snapshot(directory.appendingPathComponent(String(index)))
            guard saved.exists == snapshots[index].exists, saved.fingerprint == snapshots[index].fingerprint else {
                throw MagicWineError.integrityFailure("A saved graphics transaction DLL is missing or changed.")
            }
        }
    }

    private static func validateActiveBackup(journal: Journal, transaction: URL, after: Bool) throws {
        let active = transaction.appendingPathComponent(after ? "after-active" : "before-active")
        guard after ? journal.hasActive : journal.hadActive else {
            guard try !fs.exists(active) else { throw MagicWineError.integrityFailure("The graphics transaction has an unexpected active backup.") }
            return
        }
        let manifest = try readManifest(active)
        let metadata = after ? journal.nextMetadata : journal.previousMetadata
        let configuration = try JSONDecoder().decode(Bottle.self, from: metadata).graphics
        let expectedPaths = (after ? journal.nextPaths : journal.previousPaths) ?? journal.resolvedPaths
        guard manifest.resolvedPaths == expectedPaths, manifest.resolvedBackend == configuration.backend,
              manifest.componentID == configuration.componentID else {
            throw MagicWineError.integrityFailure("The bottle graphics recovery backup does not match its journal.")
        }
        if after {
            for (index, path) in manifest.resolvedPaths.enumerated() {
                guard let journalIndex = journal.resolvedPaths.firstIndex(of: path),
                      journal.after[journalIndex].fingerprint == "file:" + manifest.entries[index].installedHash else {
                    throw MagicWineError.integrityFailure("The graphics transaction DLLs do not match their active backup.")
                }
            }
        }
    }

    private static func validateDestinations(prefix: URL, paths: [String]) throws {
        let bottleDirectory = prefix.deletingLastPathComponent()
        let bottlesDirectory = bottleDirectory.deletingLastPathComponent()
        try ensureDirectory(bottlesDirectory.deletingLastPathComponent())
        try ensureDirectory(bottlesDirectory)
        try ensureDirectory(prefix.deletingLastPathComponent())
        try ensureDirectory(prefix)
        for path in ["drive_c", "drive_c/windows", "drive_c/windows/system32", "drive_c/windows/syswow64"] {
            try ensureDirectory(prefix.appendingPathComponent(path))
        }
        for path in paths {
            let file = prefix.appendingPathComponent(path)
            if try fs.exists(file) { try requireFileOrLink(file) }
        }
    }

    private static func preserve(_ file: URL, path: String, graphics: URL) throws {
        let recovered = graphics.appendingPathComponent("recovered", isDirectory: true)
        try ensureDirectory(recovered, create: true)
        let group = recovered.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ensureDirectory(group, create: true)
        let architecture = path.hasPrefix("drive_c/windows/system32/") ? "x64" : "x32"
        try manager.moveItem(at: file, to: group.appendingPathComponent(architecture + "-" + file.lastPathComponent))
    }

    private static func replace(_ destination: URL, with source: URL, exists sourceExists: Bool) throws {
        if try fs.exists(destination) { try manager.removeItem(at: destination) }
        if sourceExists { try manager.copyItem(at: source, to: destination) }
    }

    private static func snapshot(_ url: URL) throws -> Snapshot {
        guard try fs.exists(url) else { return Snapshot(exists: false, fingerprint: nil) }
        try requireFileOrLink(url)
        if try fs.fileType(url) == mode_t(S_IFLNK) {
            return Snapshot(exists: true, fingerprint: "link:" + (try manager.destinationOfSymbolicLink(atPath: url.path)))
        }
        return Snapshot(exists: true, fingerprint: "file:" + (try hash(url)).hex)
    }

    private static func hash(_ url: URL) throws -> (hex: String, size: UInt64) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw fileError("Cannot read a graphics DLL") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw MagicWineError.unsafeFilesystem("Graphics DLL hashing requires a regular file.")
        }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), UInt64(status.st_size))
    }

    private static func ensureDirectory(_ url: URL, create: Bool = false) throws {
        if create, try !fs.exists(url) {
            do { try manager.createDirectory(at: url, withIntermediateDirectories: false) }
            catch {
                // Independent store processes can create the shared lock directory at once.
                guard (try? fs.fileType(url)) == mode_t(S_IFDIR) else { throw error }
            }
        }
        guard try fs.fileType(url) == mode_t(S_IFDIR) else {
            throw MagicWineError.unsafeFilesystem("Graphics setup requires an owned directory, not a symlink: \(url.path)")
        }
    }

    private static func requireRegularFile(_ url: URL) throws {
        guard try fs.fileType(url) == mode_t(S_IFREG) else {
            throw MagicWineError.unsafeFilesystem("Graphics setup requires a regular file: \(url.path)")
        }
    }

    private static func requireFileOrLink(_ url: URL) throws {
        let type = try fs.fileType(url)
        guard type == mode_t(S_IFREG) || type == mode_t(S_IFLNK) else {
            throw MagicWineError.unsafeFilesystem("Refusing to replace a non-file graphics DLL: \(url.path)")
        }
    }

    private static func fileError(_ detail: String) -> MagicWineError {
        .setup("\(detail): \(String(cString: strerror(errno)))")
    }
}
