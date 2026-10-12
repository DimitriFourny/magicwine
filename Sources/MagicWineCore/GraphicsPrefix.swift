import CryptoKit
import Darwin
import Foundation

/// Prefix changes and their metadata commit share a cross-process lock. The journal is
/// published before any DLL is touched; recovery chooses solely by the atomic metadata commit.
internal enum GraphicsPrefix {
    static let dllPaths = [
        "drive_c/windows/system32/d3d10core.dll", "drive_c/windows/system32/d3d11.dll",
        "drive_c/windows/syswow64/d3d10core.dll", "drive_c/windows/syswow64/d3d11.dll"
    ]
    private static let sourcePaths = ["x64/d3d10core.dll", "x64/d3d11.dll", "x32/d3d10core.dll", "x32/d3d11.dll"]
    private static var manager: FileManager { FileManager.default }

    private struct Entry: Codable {
        let originalExists: Bool
        let installedHash: String
        let installedSize: UInt64
    }

    private struct Manifest: Codable {
        let componentID: String
        let entries: [Entry]
    }

    private struct Snapshot: Codable {
        let exists: Bool
        let fingerprint: String?
    }

    private struct Journal: Codable {
        let previousMetadata: Data
        let nextMetadata: Data
        let before: [Snapshot]
        let after: [Snapshot]
        let hadActive: Bool
        let hasActive: Bool
        let displaced: [Bool]
    }

    static func withLock<T>(bottleDirectory: URL, _ body: () throws -> T) throws -> T {
        let locks = bottleDirectory.deletingLastPathComponent().appendingPathComponent(".graphics-locks", isDirectory: true)
        try ensureDirectory(locks, create: true)
        let url = locks.appendingPathComponent(bottleDirectory.lastPathComponent + ".lock")
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw fileError("Cannot open the bottle graphics lock") }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            if errno != EINTR { throw fileError("Cannot lock the bottle graphics transaction") }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Must be called while holding withLock, including for ordinary fresh metadata reads.
    static func recover(bottleDirectory: URL) throws {
        let graphics = bottleDirectory.appendingPathComponent("graphics", isDirectory: true)
        guard try exists(graphics) else { return }
        try ensureDirectory(graphics)
        let transaction = graphics.appendingPathComponent("transaction", isDirectory: true)
        guard try exists(transaction) else { return }
        try ensureDirectory(transaction)
        let journalURL = transaction.appendingPathComponent("journal.json")
        guard try exists(journalURL) else {
            // Preparation never modifies the prefix before the journal is published.
            try manager.removeItem(at: transaction)
            return
        }
        try requireRegularFile(journalURL)
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard journal.before.count == dllPaths.count, journal.after.count == dllPaths.count,
              journal.displaced.count == dllPaths.count else {
            throw MagicWineError.setup("The bottle graphics recovery journal is invalid.")
        }
        let metadataURL = bottleDirectory.appendingPathComponent("bottle.json")
        try requireRegularFile(metadataURL)
        let metadata = try Data(contentsOf: metadataURL)
        if metadata == journal.nextMetadata {
            try manager.removeItem(at: transaction)
            return
        }
        guard metadata == journal.previousMetadata else {
            throw MagicWineError.setup("Bottle metadata changed during an interrupted graphics transaction. Its recovery files have been retained.")
        }
        let prefix = bottleDirectory.appendingPathComponent("prefix", isDirectory: true)
        try validateDestinations(prefix: prefix)
        try restoreSnapshot(journal: journal, transaction: transaction, graphics: graphics, prefix: prefix)
        try manager.removeItem(at: transaction)
    }

    /// Runtime launch checks are deliberately inexpensive. Source hashes are validated at
    /// setup; restoration uses the saved installed hashes to recognize user replacements.
    static func validateInstalled(configuration: GraphicsConfiguration, prefix: URL, bottleDirectory: URL) throws {
        guard configuration.backend == .dxvk else { return }
        try validateDestinations(prefix: prefix)
        let active = bottleDirectory.appendingPathComponent("graphics/active", isDirectory: true)
        let manifest = try readManifest(active)
        guard manifest.componentID == configuration.componentID else {
            throw MagicWineError.setup("The bottle's DXVK installation does not match its selected component. Restore Standard, then enable DXVK again.")
        }
        for (index, path) in dllPaths.enumerated() {
            let file = prefix.appendingPathComponent(path)
            try requireRegularFile(file)
            let attributes = try manager.attributesOfItem(atPath: file.path)
            guard (attributes[.size] as? NSNumber)?.uint64Value == manifest.entries[index].installedSize else {
                throw MagicWineError.setup("The bottle's DXVK DLLs are missing or changed. Restore Standard, then enable DXVK again.")
            }
        }
    }

    /// Caller holds the lock and has freshly validated owned, initialized metadata.
    /// The closure is the sole atomic metadata write and is executed after all file changes.
    static func change(from previous: GraphicsConfiguration, to next: GraphicsConfiguration,
                       componentRoot: URL?, bottleDirectory: URL, previousMetadata: Data,
                       nextMetadata: Data, commit: () throws -> Void) throws {
        if previous.backend == next.backend && previous.componentID == next.componentID {
            // In particular, a HUD-only change never reinstalls or captures managed DLLs
            // as originals. Standard reads/changes need not create a graphics directory.
            try commit()
            return
        }
        let transaction = try prepare(from: previous, to: next, componentRoot: componentRoot,
                                      bottleDirectory: bottleDirectory, previousMetadata: previousMetadata,
                                      nextMetadata: nextMetadata)
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
                        nextMetadata: Data) throws -> URL {
        guard previous.backend != .dxvk || next.backend != .dxvk else {
            throw MagicWineError.setup("In-place DXVK component updates are not supported. Create a new bottle, or choose Standard to restore this bottle's original graphics files.")
        }
        let prefix = bottleDirectory.appendingPathComponent("prefix", isDirectory: true)
        try validateDestinations(prefix: prefix)
        let graphics = bottleDirectory.appendingPathComponent("graphics", isDirectory: true)
        try ensureDirectory(graphics, create: true)
        let active = graphics.appendingPathComponent("active", isDirectory: true)
        let oldManifest: Manifest?
        if previous.backend == .dxvk {
            let manifest = try readManifest(active)
            guard manifest.componentID == previous.componentID else {
                throw MagicWineError.setup("The bottle's graphics backup does not match its selected component.")
            }
            oldManifest = manifest
        } else {
            guard try !exists(active) else { throw MagicWineError.setup("The bottle has an unexpected graphics backup; refusing to overwrite it.") }
            oldManifest = nil
        }
        if next.backend == .dxvk {
            guard let componentRoot, let id = next.componentID, !id.isEmpty,
                  ![".", ".."].contains(id), !id.contains("/"), !id.contains("\\") else {
                throw MagicWineError.setup("DXVK requires an installed graphics component.")
            }
            try ensureDirectory(componentRoot)
            for architecture in ["x64", "x32"] { try ensureDirectory(componentRoot.appendingPathComponent(architecture)) }
            for path in sourcePaths { try requireRegularFile(componentRoot.appendingPathComponent(path)) }
        }
        let transaction = graphics.appendingPathComponent("transaction", isDirectory: true)
        guard try !exists(transaction) else { throw MagicWineError.setup("A graphics transaction must be recovered before setup.") }
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
            if next.backend == .dxvk {
                try ensureDirectory(nextActive, create: true)
                try ensureDirectory(nextActive.appendingPathComponent("originals"), create: true)
            }
            var before: [Snapshot] = []
            var after: [Snapshot] = []
            var entries: [Entry] = []
            var displaced: [Bool] = []
            for (index, path) in dllPaths.enumerated() {
                let destination = prefix.appendingPathComponent(path)
                let beforeSnapshot = try snapshot(destination)
                before.append(beforeSnapshot)
                if beforeSnapshot.exists { try manager.copyItem(at: destination, to: beforeDirectory.appendingPathComponent(String(index))) }
                displaced.append(oldManifest != nil && beforeSnapshot.exists && beforeSnapshot.fingerprint != "file:" + oldManifest!.entries[index].installedHash)
                let originalExists = oldManifest?.entries[index].originalExists ?? beforeSnapshot.exists
                let original = oldManifest == nil ? destination : active.appendingPathComponent("originals/\(index)")
                if originalExists { try requireFileOrLink(original) }
                if next.backend == .dxvk {
                    if originalExists { try manager.copyItem(at: original, to: nextActive.appendingPathComponent("originals/\(index)")) }
                    let source = componentRoot!.appendingPathComponent(sourcePaths[index])
                    let staged = afterDirectory.appendingPathComponent(String(index))
                    try manager.copyItem(at: source, to: staged)
                    let digest = try hash(staged)
                    entries.append(Entry(originalExists: originalExists, installedHash: digest.hex, installedSize: digest.size))
                    after.append(Snapshot(exists: true, fingerprint: "file:" + digest.hex))
                } else {
                    let staged = afterDirectory.appendingPathComponent(String(index))
                    if originalExists { try manager.copyItem(at: original, to: staged) }
                    after.append(try snapshot(staged))
                }
            }
            if next.backend == .dxvk {
                let manifest = Manifest(componentID: next.componentID!, entries: entries)
                try JSONEncoder().encode(manifest).write(to: nextActive.appendingPathComponent("manifest.json"), options: .atomic)
            }
            let journal = Journal(previousMetadata: previousMetadata, nextMetadata: nextMetadata, before: before,
                                  after: after, hadActive: oldManifest != nil, hasActive: next.backend == .dxvk,
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
        try validateDestinations(prefix: prefix)
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: transaction.appendingPathComponent("journal.json")))
        for (index, path) in dllPaths.enumerated() {
            let destination = prefix.appendingPathComponent(path)
            if journal.displaced[index], try exists(destination) {
                try preserve(destination, index: index, graphics: graphics)
            }
            try replace(destination, with: transaction.appendingPathComponent("after/\(index)"), exists: journal.after[index].exists)
        }
        try replace(graphics.appendingPathComponent("active"), with: transaction.appendingPathComponent("after-active"), exists: journal.hasActive)
    }

    private static func restoreSnapshot(journal: Journal, transaction: URL, graphics: URL, prefix: URL) throws {
        try ensureDirectory(transaction.appendingPathComponent("before"))
        if journal.hadActive { _ = try readManifest(transaction.appendingPathComponent("before-active")) }
        // Validate all saved entries before changing anything during recovery.
        for index in dllPaths.indices where journal.before[index].exists {
            let saved = transaction.appendingPathComponent("before/\(index)")
            guard try snapshot(saved).fingerprint == journal.before[index].fingerprint else {
                throw MagicWineError.setup("A saved graphics rollback DLL is missing or changed.")
            }
        }
        for (index, path) in dllPaths.enumerated() {
            let destination = prefix.appendingPathComponent(path)
            let current = try snapshot(destination)
            if current.exists, current.fingerprint != journal.before[index].fingerprint,
               current.fingerprint != journal.after[index].fingerprint {
                try preserve(destination, index: index, graphics: graphics)
            }
            try replace(destination, with: transaction.appendingPathComponent("before/\(index)"), exists: journal.before[index].exists)
        }
        try replace(graphics.appendingPathComponent("active"), with: transaction.appendingPathComponent("before-active"), exists: journal.hadActive)
    }

    private static func readManifest(_ active: URL) throws -> Manifest {
        try ensureDirectory(active.deletingLastPathComponent())
        try ensureDirectory(active)
        let url = active.appendingPathComponent("manifest.json")
        try requireRegularFile(url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        guard manifest.entries.count == dllPaths.count else { throw MagicWineError.setup("The bottle graphics backup is invalid.") }
        try ensureDirectory(active.appendingPathComponent("originals"))
        for index in dllPaths.indices where manifest.entries[index].originalExists {
            try requireFileOrLink(active.appendingPathComponent("originals/\(index)"))
        }
        return manifest
    }

    private static func validateDestinations(prefix: URL) throws {
        let bottleDirectory = prefix.deletingLastPathComponent()
        let bottlesDirectory = bottleDirectory.deletingLastPathComponent()
        try ensureDirectory(bottlesDirectory.deletingLastPathComponent())
        try ensureDirectory(bottlesDirectory)
        try ensureDirectory(prefix.deletingLastPathComponent())
        try ensureDirectory(prefix)
        for path in ["drive_c", "drive_c/windows", "drive_c/windows/system32", "drive_c/windows/syswow64"] {
            try ensureDirectory(prefix.appendingPathComponent(path))
        }
        for path in dllPaths {
            let file = prefix.appendingPathComponent(path)
            if try exists(file) { try requireFileOrLink(file) }
        }
    }

    private static func preserve(_ file: URL, index: Int, graphics: URL) throws {
        let recovered = graphics.appendingPathComponent("recovered", isDirectory: true)
        try ensureDirectory(recovered, create: true)
        let group = recovered.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try ensureDirectory(group, create: true)
        let architecture = index < 2 ? "x64" : "x32"
        try manager.moveItem(at: file, to: group.appendingPathComponent(architecture + "-" + file.lastPathComponent))
    }

    private static func replace(_ destination: URL, with source: URL, exists sourceExists: Bool) throws {
        if try exists(destination) { try manager.removeItem(at: destination) }
        if sourceExists { try manager.copyItem(at: source, to: destination) }
    }

    private static func snapshot(_ url: URL) throws -> Snapshot {
        guard try exists(url) else { return Snapshot(exists: false, fingerprint: nil) }
        try requireFileOrLink(url)
        if try fileType(url) == mode_t(S_IFLNK) {
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
            throw MagicWineError.setup("Graphics DLL hashing requires a regular file.")
        }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), UInt64(status.st_size))
    }

    private static func exists(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 { return true }
        if errno == ENOENT { return false }
        throw fileError("Cannot inspect \(url.lastPathComponent)")
    }

    private static func ensureDirectory(_ url: URL, create: Bool = false) throws {
        if create, try !exists(url) {
            do { try manager.createDirectory(at: url, withIntermediateDirectories: false) }
            catch {
                // Independent store processes can create the shared lock directory at once.
                guard (try? fileType(url)) == mode_t(S_IFDIR) else { throw error }
            }
        }
        guard try fileType(url) == mode_t(S_IFDIR) else {
            throw MagicWineError.setup("Graphics setup requires an owned directory, not a symlink: \(url.path)")
        }
    }

    private static func requireRegularFile(_ url: URL) throws {
        guard try fileType(url) == mode_t(S_IFREG) else {
            throw MagicWineError.setup("Graphics setup requires a regular file: \(url.path)")
        }
    }

    private static func requireFileOrLink(_ url: URL) throws {
        let type = try fileType(url)
        guard type == mode_t(S_IFREG) || type == mode_t(S_IFLNK) else {
            throw MagicWineError.setup("Refusing to replace a non-file graphics DLL: \(url.path)")
        }
    }

    private static func fileType(_ url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw fileError("Cannot inspect \(url.path)") }
        return status.st_mode & mode_t(S_IFMT)
    }

    private static func fileError(_ detail: String) -> MagicWineError {
        .setup("\(detail): \(String(cString: strerror(errno)))")
    }
}
