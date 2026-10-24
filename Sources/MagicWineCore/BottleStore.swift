import Foundation

/// Each bottle is independently persisted; names never become filesystem paths.
public actor BottleStore {
    private let paths: ApplicationPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ApplicationPaths) {
        self.paths = paths
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public nonisolated func prefixURL(for bottle: Bottle) -> URL {
        paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
            .appendingPathComponent("prefix", isDirectory: true)
    }

    public func list() throws -> [Bottle] {
        try paths.prepare()
        let directories = try FileManager.default.contentsOfDirectory(
            at: paths.bottlesDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        var bottles: [Bottle] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            let bottle = try GraphicsPrefix.withLock(bottleDirectory: directory) {
                let snapshot = try decoder.decode(Bottle.self, from: Data(contentsOf: directory.appendingPathComponent("bottle.json")))
                guard snapshot.id == id else { throw MagicWineError.invalidBottle }
                return try loadUnlocked(snapshot)
            }
            bottles.append(bottle)
        }
        return bottles.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    public func create(name: String, runtime: RuntimeDescriptor) throws -> Bottle {
        let name = try validatedName(name)
        try paths.prepare()
        let bottle = Bottle(name: name, runtime: runtime)
        let directory = directoryURL(for: bottle)
        try FileManager.default.createDirectory(at: prefixURL(for: bottle), withIntermediateDirectories: true)
        do {
            try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"), options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return bottle
    }

    public func save(_ bottle: Bottle) throws {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            let current = try loadUnlocked(bottle, normalizePrograms: false)
            guard bottle.graphics == current.graphics else {
                throw MagicWineError.conflict("Graphics settings must be changed through WineRuntime.configureGraphics.")
            }
            guard bottle.display == current.display else {
                throw MagicWineError.conflict("Display settings must be changed through WineRuntime.configureDisplay.")
            }
            guard bottle.msyncEnabled == current.msyncEnabled else {
                throw MagicWineError.conflict("Synchronization settings must be changed through WineRuntime.configureSynchronization.")
            }
            guard bottle.runtime == current.runtime else {
                throw MagicWineError.conflict("The pinned runtime must be changed through WineRuntime.upgradeRuntime.")
            }
            guard bottle.isInitialized == current.isInitialized else {
                throw MagicWineError.conflict("A bottle is marked initialized only by WineRuntime.initialize.")
            }
            guard bottle.compatibility == current.compatibility else {
                throw MagicWineError.conflict("Compatibility settings must be changed through BottleStore.setCompatibility.")
            }
            guard bottle.dependencies == current.dependencies else {
                throw MagicWineError.conflict("Installed dependencies are recorded only by WineRuntime.installDependencies.")
            }
            var normalized = bottle
            for (index, program) in bottle.programs.enumerated() {
                guard let saved = current.programs.first(where: { $0.id == program.id }) else { continue }
                // Play history and favorites have their own transitions; keep the saved values.
                let kept = program.withLibraryMetadata(of: saved)
                if saved != kept {
                    throw MagicWineError.conflict("Program names and launch options must be changed through BottleStore.updateProgram.")
                }
                normalized.programs[index] = kept
            }
            _ = normalizePrograms(in: &normalized)
            try saveUnlocked(normalized)
        }
    }

    public func delete(_ bottle: Bottle) throws {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            _ = try loadUnlocked(bottle, normalizePrograms: false)
            try FileManager.default.trashItem(at: directoryURL(for: bottle), resultingItemURL: nil)
        }
        // Logs belong to the bottle, but a leftover log never undoes a completed Trash.
        try? ProcessLogs.removeLogs(forBottle: bottle.id, paths: paths)
    }

    internal func current(_ bottle: Bottle) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            try loadUnlocked(bottle)
        }
    }

    /// The only transition to `isInitialized`: WineRuntime has just created the prefix
    /// registry. Applied to the saved bottle under its lock, so settings, programs and
    /// pinned runtime another editor saved meanwhile are kept. Idempotent.
    internal func markInitialized(_ bottle: Bottle) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            var current = try loadUnlocked(bottle)
            guard !current.isInitialized else { return current }
            current.isInitialized = true
            try saveUnlocked(current)
            return current
        }
    }

    /// The runtime holds exclusive launch/lifetime leases and has verified Wine is idle.
    internal func setSynchronization(msyncEnabled: Bool, in bottle: Bottle) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            var current = try loadUnlocked(bottle)
            current.msyncEnabled = msyncEnabled
            try saveUnlocked(current)
            return current
        }
    }

    /// Only explicit, validated managed-runtime upgrades may replace the pinned descriptor.
    internal func setRuntime(_ runtime: RuntimeDescriptor, in bottle: Bottle) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            var current = try loadUnlocked(bottle)
            current.runtime = runtime
            try saveUnlocked(current)
            return current
        }
    }

    /// `componentUpdate` is `WineRuntime.updateGraphicsComponent`'s explicit in-place switch
    /// of the selected backend's component; otherwise a different component of the same
    /// backend is refused.
    internal func setGraphics(_ configuration: GraphicsConfiguration, in bottle: Bottle, componentRoot: URL?,
                              componentUpdate: Bool = false) throws -> Bottle {
        let directory = directoryURL(for: bottle)
        return try GraphicsPrefix.withLock(bottleDirectory: directory) {
            var current = try loadUnlocked(bottle)
            guard current.isInitialized else {
                throw MagicWineError.notInitialized("Set up this bottle before changing its graphics backend.")
            }
            let previous = current.graphics
            guard !componentUpdate || (previous.backend == configuration.backend && previous.backend != .standard) else {
                throw MagicWineError.conflict("This bottle's graphics backend changed before its component could be updated.")
            }
            let metadata = directory.appendingPathComponent("bottle.json")
            let previousData = try Data(contentsOf: metadata)
            current.graphics = configuration
            let nextData = try encoder.encode(current)
            try GraphicsPrefix.change(from: previous, to: configuration, componentRoot: componentRoot,
                                      bottleDirectory: directory, previousMetadata: previousData,
                                      nextMetadata: nextData, componentUpdate: componentUpdate) {
                try nextData.write(to: metadata, options: .atomic)
            }
            return current
        }
    }

    /// HUD is launch environment only: no prefix DLL, component, or running process is
    /// touched. The caller's backend/component must still be current, so a stale view
    /// cannot attach a HUD preference to a selection it never saw.
    internal func setGraphicsHUD(_ showHUD: Bool, in bottle: Bottle) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            var current = try loadUnlocked(bottle)
            guard current.graphics.backend == bottle.graphics.backend,
                  current.graphics.componentID == bottle.graphics.componentID else {
                throw MagicWineError.conflict("This bottle's graphics backend changed before the HUD could be changed.")
            }
            guard current.isInitialized, current.graphics.backend != .standard else {
                throw MagicWineError.invalidInput("Standard graphics has no managed HUD; only DXVK, DXMT, and D3DMetal have one.")
            }
            guard current.graphics.usesSupportedComponent else {
                throw MagicWineError.componentInvalid("This bottle uses an unsupported \(current.graphics.backend.displayName) component.")
            }
            guard current.graphics.showHUD != showHUD else { return current }
            current.graphics.showHUD = showHUD
            try saveUnlocked(current)
            return current
        }
    }

    /// Launch switches only: no prefix file, component, or running process is touched,
    /// so this is allowed while programs run and applies to later launches. The caller's
    /// `bottle.compatibility` is what it showed; if another editor saved different
    /// switches since, nothing is written.
    public func setCompatibility(_ options: CompatibilityOptions, in bottle: Bottle) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            var current = try loadUnlocked(bottle)
            guard current.compatibility == bottle.compatibility else {
                throw MagicWineError.conflict("This bottle's compatibility settings were changed elsewhere.")
            }
            guard current.compatibility != options else { return current }
            current.compatibility = options
            try saveUnlocked(current)
            return current
        }
    }

    /// The runtime installed `record` and its post-install checks passed. Metadata only;
    /// an earlier record of the same dependency is replaced.
    internal func recordDependency(_ record: InstalledDependency, in bottle: Bottle) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            var current = try loadUnlocked(bottle)
            current.dependencies.removeAll { $0.id == record.id }
            current.dependencies.append(record)
            try saveUnlocked(current)
            return current
        }
    }

    internal func displayNeedsUpdate(_ bottle: Bottle) throws -> Bool {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            let current = try loadUnlocked(bottle)
            return try BottleDisplay.needsUpdate(current.display, prefix: prefixURL(for: current))
        }
    }

    /// The runtime holds exclusive launch/lifetime leases and has waited for Wine to exit.
    internal func prepareDisplay(_ bottle: Bottle, configuration: DisplayConfiguration? = nil) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            var current = try loadUnlocked(bottle)
            if let configuration { current.display = configuration }
            let prefix = prefixURL(for: current)
            // Validate before retaining the original bytes for a failed metadata commit.
            _ = try BottleDisplay.needsUpdate(current.display, prefix: prefix)
            let registry = prefix.appendingPathComponent("user.reg")
            let previous = FileManager.default.fileExists(atPath: registry.path) ? try Data(contentsOf: registry) : nil
            try BottleDisplay.apply(current.display, prefix: prefix)
            do {
                try saveUnlocked(current)
            } catch {
                if let previous {
                    try previous.write(to: registry, options: .atomic)
                } else {
                    try FileManager.default.removeItem(at: registry)
                }
                throw error
            }
            return current
        }
    }

    public func registerProgram(in bottle: Bottle, executableURL: URL, name: String? = nil) throws -> Bottle {
        try mutateCurrent(bottle) { current, identities in
            let executable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
            let ext = executable.pathExtension.lowercased()
            let attributes = try? executable.resourceValues(forKeys: [.isRegularFileKey])
            guard executable.isFileURL, ["exe", "lnk", "url"].contains(ext), attributes?.isRegularFile == true else {
                throw MagicWineError.invalidProgram(executable.path)
            }
            guard !current.programs.contains(where: { $0.executablePath == executable.path }) else { return }
            let identity = WindowsShortcut.launchIdentity(for: executable, prefix: prefixURL(for: current))
            guard identities.insert(identity).inserted else { return }
            let programName = try validatedName(name ?? executable.deletingPathExtension().lastPathComponent)
            current.programs.append(WindowsProgram(name: programName, executablePath: executable.path))
            current.programs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public func removeProgram(id: UUID, in bottle: Bottle) throws -> Bottle {
        try mutateCurrent(bottle) { current, _ in
            current.programs.removeAll { $0.id == id }
        }
    }

    /// Saves a program's name and launch options. Metadata only: allowed while programs
    /// run and used by the next launch. `original` is the record the edit started from;
    /// if the saved record differs, another editor changed it and nothing is written.
    public func updateProgram(_ program: WindowsProgram, from original: WindowsProgram, in bottle: Bottle) throws -> Bottle {
        try mutateCurrent(bottle) { current, _ in
            guard let index = current.programs.firstIndex(where: { $0.id == program.id }) else {
                throw MagicWineError.conflict("\(original.name) is no longer saved in this bottle.")
            }
            // Play history and favorites may change while the editor is open; they are kept.
            guard original.id == program.id, current.programs[index] == original.withLibraryMetadata(of: current.programs[index]) else {
                throw MagicWineError.conflict("\(original.name) was changed elsewhere.")
            }
            guard program.executablePath == original.executablePath else {
                throw MagicWineError.invalidInput("A saved program's file cannot be changed. Add the other file as a new program.")
            }
            var updated = program.withLibraryMetadata(of: current.programs[index])
            updated.name = try validatedName(program.name)
            try updated.validateLaunchOptions()
            if updated.workingDirectory != original.workingDirectory {
                updated.workingDirectory = try updated.launchDirectory()?.path
            }
            current.programs[index] = updated
            current.programs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    /// MagicWine started `programID` at `date`. Metadata only, allowed while programs run;
    /// a program removed in the meantime is not recorded.
    public func recordLaunch(of programID: UUID, at date: Date, in bottle: Bottle) throws -> Bottle {
        try updateLibraryMetadata(of: programID, in: bottle, requireProgram: false) { $0.lastLaunchedAt = date }
    }

    /// Adds one finished session (from the program's start until its processes ended) to its
    /// play time. Metadata only; a program removed in the meantime is not recorded.
    public func addPlayTime(_ duration: TimeInterval, to programID: UUID, in bottle: Bottle) throws -> Bottle {
        guard duration.isFinite, duration >= 0 else {
            throw MagicWineError.invalidInput("A play session must last zero or more seconds.")
        }
        return try updateLibraryMetadata(of: programID, in: bottle, requireProgram: false) { $0.playTime += duration }
    }

    /// Marks a program as a favorite, listed first in the app. Metadata only.
    public func setFavorite(_ isFavorite: Bool, programID: UUID, in bottle: Bottle) throws -> Bottle {
        try updateLibraryMetadata(of: programID, in: bottle, requireProgram: true) { $0.isFavorite = isFavorite }
    }

    /// The only writer of play history and favorites: applied to the saved program under the
    /// bottle lock, so launch options or other history saved meanwhile are kept.
    private func updateLibraryMetadata(of programID: UUID, in bottle: Bottle, requireProgram: Bool,
                                       _ change: (inout WindowsProgram) -> Void) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            var current = try loadUnlocked(bottle)
            guard let index = current.programs.firstIndex(where: { $0.id == programID }) else {
                guard !requireProgram else {
                    throw MagicWineError.conflict("This program is no longer saved in this bottle.")
                }
                return current
            }
            let previous = current.programs[index]
            change(&current.programs[index])
            guard current.programs[index] != previous else { return current }
            try saveUnlocked(current)
            return current
        }
    }

    public func discoverPrograms(in bottle: Bottle) throws -> Bottle {
        try mutateCurrent(bottle) { current, identities in
            let prefix = prefixURL(for: bottle)
            try BottleDesktop.prepare(prefix: prefix)
            let drive = prefix.appendingPathComponent("drive_c", isDirectory: true)
            let roots = [drive.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs"),
                         drive.appendingPathComponent("users")]
            var known = Set(current.programs.map(\.executablePath))
            for root in roots {
                guard let enumerator = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in false }) else { continue }
                var candidates: [URL] = []
                for case let candidate as URL in enumerator {
                    let attributes = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                    if attributes.isSymbolicLink == true {
                        if attributes.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }
                    if root.lastPathComponent == "users", attributes.isDirectory == true {
                        let relativeDepth = enumerator.level
                        // At each user's root, only Desktop and AppData can contain launchers.
                        if relativeDepth == 2, !["Desktop", "AppData"].contains(candidate.lastPathComponent) {
                            enumerator.skipDescendants()
                        }
                        if relativeDepth == 3, candidate.deletingLastPathComponent().lastPathComponent == "AppData",
                           candidate.lastPathComponent != "Roaming" { enumerator.skipDescendants() }
                    }
                    guard attributes.isRegularFile == true,
                          ["lnk", "url"].contains(candidate.pathExtension.lowercased()) else { continue }
                    let relative = candidate.pathComponents.suffix(enumerator.level).joined(separator: "/")
                    if root.lastPathComponent == "users",
                       !relative.contains("/Desktop/"), !relative.contains("/Start Menu/Programs/") { continue }
                    let name = candidate.deletingPathExtension().lastPathComponent
                    if name.localizedCaseInsensitiveContains("uninstall") { continue }
                    candidates.append(candidate)
                }
                // Shared menus win over user folders; sorted paths make each root deterministic.
                candidates.sort { $0.path < $1.path }
                for candidate in candidates {
                    guard known.insert(candidate.path).inserted,
                          identities.insert(WindowsShortcut.launchIdentity(for: candidate, prefix: prefix)).inserted else { continue }
                    current.programs.append(WindowsProgram(name: candidate.deletingPathExtension().lastPathComponent,
                                                          executablePath: candidate.path))
                }
            }
            current.programs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    public func settings() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: paths.settingsURL.path) else { return AppSettings() }
        return try decoder.decode(AppSettings.self, from: Data(contentsOf: paths.settingsURL))
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try paths.prepare()
        try encoder.encode(settings).write(to: paths.settingsURL, options: [.atomic])
    }

    private func directoryURL(for bottle: Bottle) -> URL {
        paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw MagicWineError.invalidName }
        return trimmed
    }

    private func validateOwnership(_ bottle: Bottle) throws {
        let directory = directoryURL(for: bottle)
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true,
              directory.resolvingSymlinksInPath().deletingLastPathComponent() == paths.bottlesDirectory.resolvingSymlinksInPath() else {
            throw MagicWineError.invalidBottle
        }
        let metadata = directory.appendingPathComponent("bottle.json")
        let metadataAttributes = try metadata.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard metadataAttributes.isSymbolicLink != true else { throw MagicWineError.invalidBottle }
        let current = try decoder.decode(Bottle.self, from: Data(contentsOf: metadata))
        guard current.id == bottle.id else { throw MagicWineError.invalidBottle }
    }

    private func loadUnlocked(_ bottle: Bottle, normalizePrograms shouldNormalize: Bool = true) throws -> Bottle {
        try validateOwnership(bottle)
        try GraphicsPrefix.recover(bottleDirectory: directoryURL(for: bottle))
        var current = try decoder.decode(Bottle.self, from: Data(contentsOf: directoryURL(for: bottle).appendingPathComponent("bottle.json")))
        if !current.hasDisplayConfiguration {
            current.display = try BottleDisplay.existingConfiguration(prefix: prefixURL(for: current)) ?? .init()
        }
        if shouldNormalize { _ = normalizePrograms(in: &current) }
        return current
    }

    private func saveUnlocked(_ bottle: Bottle) throws {
        _ = try validatedName(bottle.name)
        try encoder.encode(bottle).write(to: directoryURL(for: bottle).appendingPathComponent("bottle.json"), options: .atomic)
    }

    private func normalizePrograms(in bottle: inout Bottle) -> Set<WindowsShortcut.LaunchIdentity> {
        let prefix = prefixURL(for: bottle)
        var paths: Set<String> = []
        var identities: Set<WindowsShortcut.LaunchIdentity> = []
        paths.reserveCapacity(bottle.programs.count)
        identities.reserveCapacity(bottle.programs.count)
        bottle.programs.removeAll { program in
            guard paths.insert(program.executablePath).inserted else { return true }
            return !identities.insert(WindowsShortcut.launchIdentity(
                for: URL(fileURLWithPath: program.executablePath), prefix: prefix)).inserted
        }
        return identities
    }

    private func mutateCurrent(_ bottle: Bottle,
                               _ mutation: (inout Bottle, inout Set<WindowsShortcut.LaunchIdentity>) throws -> Void) throws -> Bottle {
        try GraphicsPrefix.withLock(bottleDirectory: directoryURL(for: bottle)) {
            var current = try loadUnlocked(bottle, normalizePrograms: false)
            var identities = normalizePrograms(in: &current)
            try mutation(&current, &identities)
            try saveUnlocked(current)
            return current
        }
    }
}
