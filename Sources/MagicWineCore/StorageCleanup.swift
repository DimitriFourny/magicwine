import Darwin
import Foundation

/// One removable library entry. Only `StorageCleanup.plan` creates items, and
/// `StorageCleanup.apply` removes one only if a fresh plan still contains it.
public struct StorageCleanupItem: Identifiable, Hashable, Sendable {
    public enum Category: String, CaseIterable, Sendable {
        case component, runtime, runtimeView, staging, lock

        public var title: String {
            switch self {
            case .component: "Unused graphics components"
            case .runtime: "Unused managed Wine runtimes"
            case .runtimeView: "Stale private runtime views"
            case .staging: "Leftover installation staging"
            case .lock: "Lock files of deleted bottles"
            }
        }
    }

    public let category: Category
    public let url: URL
    /// Allocated bytes counted without following links. APFS clones and hard links
    /// shared with kept files can make the space actually reclaimed smaller.
    public let size: Int64
    /// Why nothing in the library references this entry.
    public let reason: String
    /// A user-imported D3DMetal component: MagicWine cannot recreate it; the
    /// libraries must be imported again before a bottle can select it.
    public let requiresReimport: Bool
    /// The current managed Wine or a currently bundled component: recreatable, but
    /// expensive, so plans keep it unless the caller explicitly includes it.
    public let isCurrent: Bool
    /// Directory names below the library root that contain this entry.
    let parent: [String]
    let name: String

    public var id: String { category.rawValue + ":" + url.path }
}

public struct StorageCleanupPlan: Sendable {
    public let items: [StorageCleanupItem]
    /// Unreferenced current Wine/bundled components kept because they were not included.
    public let keptCurrent: [StorageCleanupItem]
    public var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

public struct StorageCleanupResult: Sendable {
    public let removed: [StorageCleanupItem]
    /// Confirmed items that a fresh plan no longer contains (now referenced, already
    /// removed, or changed type); they were left untouched.
    public let skipped: [StorageCleanupItem]
    public var reclaimedSize: Int64 { removed.reduce(0) { $0 + $1.size } }
}

/// Finds and removes runtimes, components, private runtime views, installer staging
/// and lock files that nothing in an `ApplicationPaths` library references. It never
/// touches bottle directories or anything outside `Runtimes/`, `Components/` and
/// `Bottles/.graphics-locks/`.
public enum StorageCleanup {
    /// Installers remove their own staging directories; one untouched this long is abandoned.
    static let stagingGracePeriod: TimeInterval = 24 * 60 * 60
    private static let viewsName = ".graphics-views"
    private static let locksName = ".graphics-locks"
    private static let cleanupPrefix = ".cleanup-"

    /// A read-only plan. Current managed Wine and bundled components are only listed in
    /// `keptCurrent` unless `includeCurrent` is set.
    public static func plan(paths: ApplicationPaths, includeCurrent: Bool = false) async throws -> StorageCleanupPlan {
        let store = BottleStore(paths: paths)
        let bottles = try await store.list()
        let all = try candidates(paths: paths, bottles: bottles, settings: try await store.settings())
        return StorageCleanupPlan(items: all.filter { includeCurrent || !$0.isCurrent },
                                  keptCurrent: includeCurrent ? [] : all.filter(\.isCurrent))
    }

    /// Removes the confirmed items that a plan recomputed under every bottle's exclusive
    /// launch and lifetime leases still contains. Refuses while any bottle is launching,
    /// running, being configured, or has a live Wine server.
    public static func apply(_ confirmed: [StorageCleanupItem], paths: ApplicationPaths) async throws -> StorageCleanupResult {
        guard !confirmed.isEmpty else { return StorageCleanupResult(removed: [], skipped: []) }
        let store = BottleStore(paths: paths)
        try paths.prepare()
        let cleanupLock = try acquireCleanupLock(paths: paths)
        // Unlock explicitly: a child forked by another thread can briefly share this
        // descriptor until it execs, and close alone would keep the lock held meanwhile.
        defer {
            _ = flock(cleanupLock, LOCK_UN)
            close(cleanupLock)
        }
        let (bottles, leases) = try await idleBottles(store: store, paths: paths)
        defer { leases.forEach { $0.release() } }
        let fresh = try candidates(paths: paths, bottles: bottles, settings: try await store.settings())
        let wanted = Set(confirmed.map(\.id))
        let removable = fresh.filter { wanted.contains($0.id) }
        let removableIDs = Set(removable.map(\.id))
        var removed: [StorageCleanupItem] = []
        var skipped = confirmed.filter { !removableIDs.contains($0.id) }
        for item in removable {
            try Task.checkCancellation()
            if try remove(item, paths: paths) { removed.append(item) } else { skipped.append(item) }
        }
        return StorageCleanupResult(removed: removed, skipped: skipped)
    }

    // MARK: Planning

    private struct ViewInputs: Hashable {
        let runtime: String
        let component: String
        let backend: GraphicsBackend
    }

    static func candidates(paths: ApplicationPaths, bottles: [Bottle], settings: AppSettings) throws -> [StorageCleanupItem] {
        guard try fileType(paths.root) == S_IFDIR else { throw unsafe("The library root must be an ordinary directory: \(paths.root.path).") }
        let now = Date()
        var items: [StorageCleanupItem] = []
        func item(_ category: StorageCleanupItem.Category, _ parent: [String], _ name: String, reason: String,
                  requiresReimport: Bool = false, isCurrent: Bool = false) -> StorageCleanupItem {
            let url = location(paths, parent, name)
            return StorageCleanupItem(category: category, url: url, size: usage(url).size, reason: reason,
                                      requiresReimport: requiresReimport, isCurrent: isCurrent, parent: parent, name: name)
        }
        func staging(_ parent: [String], _ name: String) -> StorageCleanupItem? {
            let url = location(paths, parent, name)
            guard (try? fileType(url)) == S_IFDIR else { return nil }
            if name.hasPrefix(cleanupPrefix) {
                return item(.staging, parent, name, reason: "An interrupted storage cleanup left this partly removed entry.")
            }
            let found = usage(url)
            guard found.complete, now.timeIntervalSince(found.newest) >= stagingGracePeriod else { return nil }
            return item(.staging, parent, name, reason: "An interrupted installation left this staging directory; nothing in it changed for over 24 hours.")
        }

        let executables = bottles.map(\.runtime.executableURL) +
            [settings.customWinePath, settings.preferredRuntimePath].compactMap { $0.map { URL(fileURLWithPath: $0) } }
        let references = Set(executables.flatMap(forms))
        let current = RuntimeInstallation.destination(paths: paths).lastPathComponent
        for name in try entries(paths.runtimesDirectory) {
            if [".install-", cleanupPrefix].contains(where: name.hasPrefix) {
                if let found = staging(["Runtimes"], name) { items.append(found) }
                continue
            }
            let url = paths.runtimesDirectory.appendingPathComponent(name, isDirectory: true)
            guard isManagedRuntimeName(name), try fileType(url) == S_IFDIR else { continue }
            let directories = forms(url)
            guard !references.contains(where: { reference in directories.contains { reference.hasPrefix($0 + "/") } }) else { continue }
            let isCurrent = name == current
            items.append(item(.runtime, ["Runtimes"], name,
                              reason: "No bottle is pinned to this managed Wine and settings.json does not select it."
                                + (isCurrent ? " It is the current managed Wine; Install / Update Wine would download it again." : ""),
                              isCurrent: isCurrent))
        }

        let views = paths.runtimesDirectory.appendingPathComponent(viewsName, isDirectory: true)
        if try fileType(paths.runtimesDirectory) == S_IFDIR, try fileType(views) == S_IFDIR {
            let (reachable, undetermined) = try reachableViews(paths: paths, bottles: bottles)
            for name in try entries(views) {
                if [".install-", cleanupPrefix].contains(where: name.hasPrefix) {
                    if let found = staging(["Runtimes", viewsName], name) { items.append(found) }
                    continue
                }
                guard name.count == 64, name.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
                      !reachable.contains(name), try fileType(views.appendingPathComponent(name)) == S_IFDIR else { continue }
                let inputs = GraphicsRuntimeView.receiptInputs(of: views.appendingPathComponent(name, isDirectory: true))
                    .map { ViewInputs(runtime: $0.runtime, component: $0.component, backend: $0.backend) }
                // A bottle whose view identity could not be computed keeps every view
                // that might be its own; never guess which one launch would use.
                if let inputs, undetermined.contains(inputs) { continue }
                if inputs == nil, !undetermined.isEmpty { continue }
                let reason: String
                if let inputs {
                    let component = URL(fileURLWithPath: inputs.component).lastPathComponent
                    reason = "No bottle's current Wine and component produce this view (built for \(inputs.backend.displayName) \(component) with \(inputs.runtime)). Launch rebuilds a needed view."
                } else {
                    reason = "Its receipt is missing or unreadable, so launch can never reuse it."
                }
                items.append(item(.runtimeView, ["Runtimes", viewsName], name, reason: reason))
            }
        }

        let componentIDs = Set(bottles.compactMap(\.graphics.componentID))
        for name in try entries(paths.componentsDirectory) {
            if [".install-", ".d3dmetal-", cleanupPrefix].contains(where: name.hasPrefix) {
                if let found = staging(["Components"], name) { items.append(found) }
                continue
            }
            guard let provider = GraphicsComponentProviders.bundled.all.first(where: { name.hasPrefix($0.componentPrefix) })
            else { continue }
            let kind = provider.backend.displayName
            guard !componentIDs.contains(name),
                  try fileType(paths.componentsDirectory.appendingPathComponent(name)) == S_IFDIR else { continue }
            let imported = provider.isImported, isCurrent = provider.currentComponentID == name
            var reason = "No bottle uses this \(kind) component."
            if isCurrent { reason += " It is the currently bundled version; MagicWine reinstalls it when a bottle selects \(kind) again." }
            if imported { reason += " These are your imported Apple libraries: using D3DMetal again requires importing them again." }
            items.append(item(.component, ["Components"], name, reason: reason, requiresReimport: imported, isCurrent: isCurrent))
        }

        let locks = paths.bottlesDirectory.appendingPathComponent(locksName, isDirectory: true)
        if try fileType(paths.bottlesDirectory) == S_IFDIR, try fileType(locks) == S_IFDIR {
            for name in try entries(locks) {
                guard let owner = lockOwner(name), try fileType(locks.appendingPathComponent(name)) == S_IFREG,
                      try fileType(paths.bottlesDirectory.appendingPathComponent(owner.uuidString)) == nil else { continue }
                items.append(item(.lock, ["Bottles", locksName], name, reason: "Bottle \(owner.uuidString) no longer exists."))
            }
        }
        let order = StorageCleanupItem.Category.allCases
        return items.sorted {
            $0.category == $1.category ? $0.url.path < $1.url.path
                : order.firstIndex(of: $0.category)! < order.firstIndex(of: $1.category)!
        }
    }

    /// Exactly the view identities `GraphicsRuntimeView.prepare` would use for every
    /// bottle's current Wine and component, plus inputs whose identity is undeterminable.
    private static func reachableViews(paths: ApplicationPaths,
                                       bottles: [Bottle]) throws -> (Set<String>, Set<ViewInputs>) {
        var reachable = Set<String>(), undetermined = Set<ViewInputs>(), seen = Set<ViewInputs>()
        for bottle in bottles where bottle.graphics.backend.componentProvider?.viewSubstitutions.isEmpty == false {
            guard let componentID = bottle.graphics.componentID else { continue }
            // Same URLs launch passes: the pinned executable and Components/<ID>.
            let executable = bottle.runtime.executableURL
            let component = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
            let inputs = ViewInputs(runtime: executable.deletingLastPathComponent().deletingLastPathComponent()
                                        .resolvingSymlinksInPath().path,
                                    component: component.path, backend: bottle.graphics.backend)
            guard seen.insert(inputs).inserted else { continue }
            // A missing runtime or component cannot launch, so no view is reachable from it.
            guard FileManager.default.fileExists(atPath: executable.path), try fileType(component) == S_IFDIR else { continue }
            do {
                reachable.insert(try GraphicsRuntimeView.identity(executable: executable, component: component,
                                                                  backend: bottle.graphics.backend))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                undetermined.insert(inputs)
            }
        }
        return (reachable, undetermined)
    }

    private static func isManagedRuntimeName(_ name: String) -> Bool {
        // wine-<version>-<12-hex archive digest>-<driver component>
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count >= 4 && parts[0] == "wine" && !parts[1].isEmpty && !parts.last!.isEmpty &&
            parts.dropFirst(2).dropLast().contains { $0.count == 12 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    }

    private static func lockOwner(_ name: String) -> UUID? {
        guard name.hasSuffix(".lock") else { return nil }
        var stem = String(name.dropLast(5))
        for kind in ["-launch", "-lifetime"] where stem.hasSuffix(kind) { stem.removeLast(kind.count) }
        guard let id = UUID(uuidString: stem), id.uuidString == stem else { return nil }
        return id
    }

    private static func forms(_ url: URL) -> [String] {
        let standardized = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        return standardized == resolved ? [standardized] : [standardized, resolved]
    }

    private static func location(_ paths: ApplicationPaths, _ parent: [String], _ name: String) -> URL {
        (parent + [name]).reduce(paths.root) { $0.appendingPathComponent($1) }
    }

    /// Names in an ordinary managed directory; an absent directory has none.
    private static func entries(_ directory: URL) throws -> [String] {
        switch try fileType(directory) {
        case nil: return []
        case S_IFDIR: return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        default: throw unsafe("\(directory.path) must be an ordinary directory, not a link.")
        }
    }

    /// The `lstat` file type, or nil when nothing exists at that path.
    private static func fileType(_ url: URL) throws -> mode_t? {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            if errno == ENOENT { return nil }
            throw failure("Cannot inspect \(url.path): \(String(cString: strerror(errno))).")
        }
        return status.st_mode & S_IFMT
    }

    /// Allocated size and newest modification below `url`, never following links.
    private static func usage(_ url: URL) -> (size: Int64, newest: Date, complete: Bool) {
        var size: Int64 = 0, newest = Date.distantPast, complete = true
        var linked = Set<[UInt64]>()
        func visit(_ path: String) {
            var status = stat()
            guard lstat(path, &status) == 0 else { complete = false; return }
            let modified = Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
            if modified > newest { newest = modified }
            if status.st_nlink <= 1 || status.st_mode & S_IFMT == S_IFDIR ||
                linked.insert([UInt64(UInt32(bitPattern: status.st_dev)), status.st_ino]).inserted {
                size += Int64(status.st_blocks) * 512
            }
            guard status.st_mode & S_IFMT == S_IFDIR else { return }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { complete = false; return }
            for name in names { visit(path + "/" + name) }
        }
        visit(url.path)
        return (size, newest, complete)
    }

    // MARK: Applying

    /// Serializes cleanups across processes; installers and launches use their own leases.
    private static func acquireCleanupLock(paths: ApplicationPaths) throws -> Int32 {
        guard try fileType(paths.bottlesDirectory) == S_IFDIR else {
            throw unsafe("The bottle storage directory must be an ordinary directory, not a link.")
        }
        let directory = paths.bottlesDirectory.appendingPathComponent(locksName, isDirectory: true)
        if directory.path.withCString({ mkdir($0, 0o700) }) != 0, errno != EEXIST {
            throw failure("Cannot create the lock directory: \(String(cString: strerror(errno))).")
        }
        guard try fileType(directory) == S_IFDIR else { throw unsafe("The lock directory must be an ordinary directory, not a link.") }
        let descriptor = open(directory.appendingPathComponent("storage-cleanup.lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw failure("Cannot open the storage cleanup lock: \(String(cString: strerror(errno))).") }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
            close(descriptor)
            throw unsafe("The storage cleanup lock must be a regular file without hard links.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw MagicWineError.busy("Storage cleanup: Another storage cleanup is running for this library. Nothing was removed.", reason: .operationInProgress)
        }
        return descriptor
    }

    /// Holds every bottle's exclusive launch and lifetime lease without waiting, then
    /// probes its Wine server like `WineRuntime` does before changing Wine settings.
    private static func idleBottles(store: BottleStore,
                                    paths: ApplicationPaths) async throws -> ([Bottle], [GraphicsOperationLease]) {
        var leases: [GraphicsOperationLease] = []
        var locked = Set<UUID>()
        do {
            // A bottle created while locking is locked too; the final listing is stable.
            for _ in 0..<3 {
                let bottles = try await store.list()
                let newcomers = bottles.filter { !locked.contains($0.id) }
                if newcomers.isEmpty { return (bottles, leases) }
                for bottle in newcomers {
                    for kind in [GraphicsOperationLease.Kind.launch, .lifetime] {
                        do {
                            leases.append(try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id, kind: kind,
                                                                                   exclusive: true, timeout: .zero))
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            throw MagicWineError.busy("Storage cleanup: “\(bottle.name)” is launching, running, or being configured. Nothing was removed.", reason: .programsRunning)
                        }
                    }
                    locked.insert(bottle.id)
                    try await requireIdleServer(bottle, paths: paths)
                }
            }
            throw MagicWineError.busy("Storage cleanup: Bottles were created or removed while preparing cleanup; nothing was removed.", reason: .operationInProgress)
        } catch {
            leases.forEach { $0.release() }
            throw error
        }
    }

    private static func requireIdleServer(_ bottle: Bottle, paths: ApplicationPaths) async throws {
        let server = bottle.runtime.executableURL.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent("wineserver")
        // Without its pinned runtime no server can be started for this prefix.
        guard FileManager.default.isExecutableFile(atPath: server.path) else { return }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("WINE") && !$0.key.hasPrefix("DYLD_") }
        environment["WINEPREFIX"] = paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
            .appendingPathComponent("prefix", isDirectory: true).path
        // An idle probe records nothing worth keeping; a busy server leaves a bottle log.
        do {
            _ = try await ProcessOperation(executable: server, arguments: ["-w"], environment: environment, directory: nil,
                                           output: .probe(directory: ProcessLogs.bottleDirectory(bottle.id, paths: paths),
                                                          operation: "wineserver", detail: "-w"),
                                           timeout: 0.5).probe()
        } catch ProcessOperation.Interrupted.timedOut(let log) {
            throw MagicWineError.busy("Storage cleanup: The Wine server of “\(bottle.name)” is still running. Nothing was removed.", reason: .programsRunning, logURL: log)
        }
    }

    private static let allowedParents: [StorageCleanupItem.Category: [[String]]] = [
        .component: [["Components"]],
        .runtime: [["Runtimes"]],
        .runtimeView: [["Runtimes", viewsName]],
        .staging: [["Runtimes"], ["Components"], ["Runtimes", viewsName]],
        .lock: [["Bottles", locksName]],
    ]

    /// Returns false when the entry vanished or is no longer the planned kind of file.
    private static func remove(_ item: StorageCleanupItem, paths: ApplicationPaths) throws -> Bool {
        guard allowedParents[item.category]?.contains(item.parent) == true, !item.name.isEmpty,
              !item.name.contains("/"), item.name != ".", item.name != ".." else {
            throw unsafe("Refusing to remove an entry outside the managed directories: \(item.url.path).")
        }
        // Open each managed parent without following links, then work relative to it,
        // so no link can redirect removal outside the library.
        var parent = open(paths.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure("Cannot open the library root: \(String(cString: strerror(errno))).") }
        defer { close(parent) }
        for component in item.parent {
            let child = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw unsafe("\(component) must be an ordinary directory inside the library.") }
            close(parent)
            parent = child
        }
        var status = stat()
        guard fstatat(parent, item.name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return false }
            throw failure("Cannot inspect \(item.url.path): \(String(cString: strerror(errno))).")
        }
        if item.category == .lock {
            guard status.st_mode & S_IFMT == S_IFREG else { return false }
            return try removeLock(parent: parent, name: item.name, item: item)
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { return false }
        // Retire the name atomically: a half-removed runtime, component or view must
        // never remain under a name launch would trust. A failed removal leaves a
        // `.cleanup-` entry that the next plan offers again.
        let retired = cleanupPrefix + UUID().uuidString
        guard renameat(parent, item.name, parent, retired) == 0 else {
            if errno == ENOENT { return false }
            throw failure("Cannot remove \(item.url.path): \(String(cString: strerror(errno))).")
        }
        try removeTree(parent: parent, name: retired, display: item.url)
        return true
    }

    private static func removeLock(parent: Int32, name: String, item: StorageCleanupItem) throws -> Bool {
        let descriptor = openat(parent, name, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var opened = stat(), current = stat()
        // A holder still uses it; leave it for a later cleanup.
        guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return false }
        guard fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else { return false }
        guard unlinkat(parent, name, 0) == 0 else {
            throw failure("Cannot remove \(item.url.path): \(String(cString: strerror(errno))).")
        }
        return true
    }

    /// Depth-first removal relative to directory descriptors; links are removed, never followed.
    private static func removeTree(parent: Int32, name: String, display: URL) throws {
        var status = stat()
        guard fstatat(parent, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw failure("Cannot inspect an entry of \(display.path): \(String(cString: strerror(errno))).")
        }
        if status.st_mode & S_IFMT == S_IFDIR {
            let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw failure("Cannot open an entry of \(display.path): \(String(cString: strerror(errno))).") }
            defer { close(directory) }
            var opened = stat()
            guard fstat(directory, &opened) == 0, opened.st_dev == status.st_dev, opened.st_ino == status.st_ino else {
                throw unsafe("An entry of \(display.path) changed during removal.")
            }
            for child in try names(in: directory) {
                try removeTree(parent: directory, name: child, display: display)
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
                throw failure("Cannot remove a directory of \(display.path): \(String(cString: strerror(errno))).")
            }
        } else {
            guard unlinkat(parent, name, 0) == 0 else {
                throw failure("Cannot remove a file of \(display.path): \(String(cString: strerror(errno))).")
            }
        }
    }

    private static func names(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw failure("Cannot list a directory: \(String(cString: strerror(errno))).")
        }
        defer { closedir(stream) }
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }

    /// Unexpected system errors; `unsafe` covers refusals to follow links or leave the library.
    private static func failure(_ message: String) -> MagicWineError { .setup("Storage cleanup: " + message) }
    private static func unsafe(_ message: String) -> MagicWineError { .unsafeFilesystem("Storage cleanup: " + message) }
}
