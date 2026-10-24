import Foundation

public actor WineRuntime {
    public static let distributionNotice = RuntimeInstallation.notice
    public static let dxvkNotice = DXVKInstallation.notice
    public static let dxmtNotice = DXMTInstallation.notice
    public static let d3dMetalNotice = D3DMetalInstallation.notice
    /// `WINEDEBUG` of the quiet bottle setting and of a one-off diagnostic launch.
    public static let quietWineDebug = LaunchPlanner.quietWineDebug
    public static let diagnosticWineDebug = LaunchPlanner.diagnosticWineDebug
    private let paths: ApplicationPaths
    private let store: BottleStore
    private var active: [UUID: [UUID: ProcessOperation]] = [:]
    private var installing = false
    private var settingsChanging: Set<UUID> = []
    private var pendingLaunches: [UUID: [UUID: Task<GraphicsOperationLease, Error>]] = [:]
    private var installingGraphics: Set<GraphicsBackend> = []

    /// `store` is the library's single `BottleStore`; share it with every other owner
    /// of the same `paths` so the store's actor serialization spans them all.
    public init(paths: ApplicationPaths, store: BottleStore) {
        self.paths = paths
        self.store = store
    }

    /// Locates user-owned libraries without downloading or changing the bottle's Wine.
    public nonisolated static func discoverD3DMetalSource(executable: URL) -> URL? {
        D3DMetalInstallation.discoverSource(executable: executable)
    }

    private nonisolated var managedExecutableURL: URL {
        RuntimeInstallation.destination(paths: paths)
            .appendingPathComponent(RuntimeInstallation.relativeExecutable)
            .resolvingSymlinksInPath().standardizedFileURL
    }

    /// Capability belongs to the pinned managed runtime, not its Wine version string.
    public nonisolated func supportsMSync(_ runtime: RuntimeDescriptor) -> Bool {
        runtime.executableURL.resolvingSymlinksInPath().standardizedFileURL == managedExecutableURL
    }

    public nonisolated func canUpgradeRuntime(_ runtime: RuntimeDescriptor) -> Bool {
        guard !supportsMSync(runtime) else { return false }
        let root = paths.runtimesDirectory.resolvingSymlinksInPath().standardizedFileURL
        let executable = runtime.executableURL.resolvingSymlinksInPath().standardizedFileURL
        let stem = "wine-\(RuntimeInstallation.version)-\(RuntimeInstallation.archiveSHA256.prefix(12))-winemac-wine11.0-metal."
        return (1...6).contains { revision in
            executable == root.appendingPathComponent(stem + String(revision))
                .appendingPathComponent(RuntimeInstallation.relativeExecutable)
        }
    }

    /// Only current managed Wine is an automatic default; external Wine requires an explicit preference.
    public nonisolated func preferredRuntime(in runtimes: [RuntimeDescriptor], preferredPath: String?) -> RuntimeDescriptor? {
        let managed = managedExecutableURL
        if let preferredPath {
            let preferred = URL(fileURLWithPath: preferredPath).resolvingSymlinksInPath().standardizedFileURL
            let managedRoot = paths.runtimesDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            if !preferred.path.hasPrefix(managedRoot) || preferred == managed {
                return runtimes.first { $0.executableURL == preferred }
            }
        }
        return runtimes.first { $0.executableURL == managed }
    }

    public func discover() async -> [RuntimeDescriptor] {
        var candidates = [managedExecutableURL]
        let manager = FileManager.default
        for name in ["Wine Stable", "Wine Devel", "Wine Staging"] {
            candidates.append(URL(fileURLWithPath: "/Applications/\(name).app/Contents/Resources/wine/bin/wine"))
            candidates.append(manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(name).app/Contents/Resources/wine/bin/wine"))
        }
        for prefix in ["/opt/homebrew", "/usr/local"] {
            candidates.append(URL(fileURLWithPath: "\(prefix)/bin/wine"))
            candidates.append(URL(fileURLWithPath: "\(prefix)/bin/wine64"))
            candidates.append(URL(fileURLWithPath: "\(prefix)/opt/wine-stable/bin/wine"))
            for cask in ["wine-stable", "wine@devel", "wine@staging"] {
                let caskRoot = URL(fileURLWithPath: "\(prefix)/Caskroom/\(cask)")
                if let versions = try? manager.contentsOfDirectory(at: caskRoot,
                        includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    for version in versions {
                        let name = cask == "wine-stable" ? "Wine Stable" : (cask == "wine@devel" ? "Wine Devel" : "Wine Staging")
                        candidates.append(version.appendingPathComponent("\(name).app/Contents/Resources/wine/bin/wine"))
                    }
                }
            }
        }
        var seen: Set<String> = []
        var result: [RuntimeDescriptor] = []
        for candidate in candidates {
            if Task.isCancelled { break }
            let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
            // A Homebrew symlink must not silently adopt a reference manager's Wine.
            guard !isReferenceRuntime(canonical), manager.isExecutableFile(atPath: canonical.path),
                  seen.insert(canonical.path).inserted else { continue }
            if let runtime = try? await inspect(executableURL: canonical) { result.append(runtime) }
        }
        return result.sorted { $0.executableURL.path < $1.executableURL.path }
    }

    public func inspect(executableURL: URL) async throws -> RuntimeDescriptor {
        try paths.prepare()
        let executable = executableURL.resolvingSymlinksInPath().standardizedFileURL
        try validateExecutable(executable)
        let operation = ProcessOperation(executable: executable, arguments: ["--version"],
            environment: environment(executable: executable, prefix: nil), directory: nil,
            output: .probe(directory: ProcessLogs.libraryDirectory(paths: paths), operation: "wine-version", detail: nil),
            timeout: 15)
        let output: Data
        do { output = try await operation.probe().output }
        catch ProcessOperation.Interrupted.timedOut(let log) {
            throw MagicWineError.runtimeUnavailable("Wine version inspection timed out for \(executable.path). If macOS is blocking a custom Wine installation, review System Settings > Privacy & Security. For managed Wine, run Install / Update Wine again and accept the unsigned-runtime confirmation. Log: \(log.path)")
        }
        guard let version = String(decoding: output, as: UTF8.self).components(separatedBy: .newlines)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.lowercased().hasPrefix("wine-") || $0.lowercased().hasPrefix("wine ") }),
              version.count <= 256 else {
            let log = try operation.recordProbeLog(note: "No Wine version was reported.")
            throw MagicWineError.runtimeUnavailable("The selected executable did not report a Wine version. Log: \(log.path)")
        }
        return RuntimeDescriptor(executableURL: executable, version: version)
    }

    public func installRuntime(acceptUnsigned: Bool,
                               progress: (@Sendable (WineInstallationProgress) -> Void)? = nil) async throws -> RuntimeDescriptor {
        guard acceptUnsigned else {
            throw MagicWineError.setup("Installing managed Wine requires consent to run unsigned third-party code and remove its download quarantine.")
        }
        guard !installing else { throw MagicWineError.setup("A managed Wine installation is already in progress.") }
        installing = true
        defer { installing = false }
        let executable = try await RuntimeInstallation.install(paths: paths, progress: progress)
        progress?(.checkingRuntime)
        return try await inspect(executableURL: executable)
    }

    /// Creates the prefix and marks the bottle initialized. The returned bottle is the
    /// persisted one: callers replace their copy with it instead of saving anything.
    public func initialize(_ bottle: Bottle) async throws -> BottleInitialization {
        let deadline = Date().addingTimeInterval(180)
        let result = try await execute(arguments: ["wineboot", "-u"], bottle: bottle,
                                       directory: nil, timeout: 180, log: LogName("setup"))
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            await cleanup(bottle)
            throw MagicWineError.setup("Bottle setup timed out. Log: \(result.logURL.path)")
        }
        try await serverCommand("-w", in: bottle, timeout: remaining)
        let prefix = try prefixURL(for: bottle)
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
              FileManager.default.fileExists(atPath: prefix.appendingPathComponent("user.reg").path) else {
            throw MagicWineError.setup("Wine exited without creating the bottle registry. Setup log: \(result.logURL.path)")
        }
        // `wineboot -u` stages the DLLs Wine's own services had mapped; Wine would only apply
        // them when the next session starts, after the first launch prepared its prefix DLLs.
        try await completePendingBoot(try await store.current(bottle), prefix: prefix, deadline: deadline)
        return BottleInitialization(bottle: try await store.markInitialized(bottle), result: result)
    }

    public func install(_ installerURL: URL, in bottle: Bottle) async throws -> OperationResult {
        let installer = try windowsFile(installerURL, extensions: ["exe", "msi"])
        let arguments = installer.pathExtension.lowercased() == "msi"
            ? ["msiexec", "/i", installer.path] : [installer.path]
        return try await execute(arguments: arguments, bottle: bottle,
                                 directory: installer.deletingLastPathComponent(), timeout: nil,
                                 log: LogName("install", installer.lastPathComponent))
    }

    /// `onStart` runs once the program's process has started (for LNK/URL, once
    /// `start /unix` has), with any skipped-integration warnings and its log.
    ///
    /// A direct EXE's exit status is returned in `OperationResult.exitCode`, never
    /// thrown: games and launchers may quit normally with a nonzero code. It is the low
    /// 8 bits of the Windows exit code. Errors remain for failing to start, Stop,
    /// leases/validation, and a signal. For LNK/URL a nonzero `start /unix` status means
    /// Wine could not dispatch the shortcut, so it stays `processFailed`.
    ///
    /// The program's saved launch options (re-read from the bottle, so an edit made while
    /// other programs run applies here) form the highest launch layer. Arguments and the
    /// working directory apply to EXE files only.
    ///
    /// `diagnostics` is a one-off: the process gets `LaunchPlanner.diagnosticWineDebug`
    /// above every saved setting, and nothing is persisted.
    public func launch(_ program: WindowsProgram, in bottle: Bottle, diagnostics: Bool = false,
                       onStart: (@Sendable (LaunchStart) -> Void)? = nil) async throws -> OperationResult {
        let executable = try windowsFile(URL(fileURLWithPath: program.executablePath), extensions: ["exe", "lnk", "url"])
        let isShortcut = ["lnk", "url"].contains(executable.pathExtension.lowercased())
        let arguments = isShortcut ? ["start", "/unix", executable.path] : [executable.path]
        let result = try await execute(arguments: arguments, bottle: bottle,
                                       directory: executable.deletingLastPathComponent(), timeout: nil,
                                       onStart: onStart, exitStatusIsResult: !isShortcut, program: program,
                                       diagnostics: diagnostics)
        if isShortcut {
            // ShellExecute launches shortcuts asynchronously. Observe the prefix's
            // server lifetime instead of start /wait's unreliable shortcut handle.
            // A Stop while waiting reports the launch's own log.
            try await serverCommand("-w", in: bottle, timeout: nil, tracked: true, stoppedLog: result.logURL)
        }
        return result
    }

    public func configure(_ bottle: Bottle) async throws -> OperationResult {
        try await execute(arguments: ["winecfg"], bottle: bottle, directory: nil, timeout: nil, log: LogName("winecfg"))
    }

    /// Server probes keep no log unless they fail, so a successful Stop returns none.
    public func stop(_ bottle: Bottle) async throws {
        interruptOperations(in: bottle)
        try paths.prepare()
        let launch = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                              kind: .launch, exclusive: true)
        defer { launch.release() }
        try await stopProcesses(bottle)
        let lifetime = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                                kind: .lifetime, exclusive: true, timeout: .seconds(15))
        lifetime.release()
    }

    private func interruptOperations(in bottle: Bottle) {
        for pending in pendingLaunches[bottle.id]?.values ?? Dictionary<UUID, Task<GraphicsOperationLease, Error>>().values {
            pending.cancel()
        }
        for operation in active[bottle.id]?.values ?? Dictionary<UUID, ProcessOperation>().values {
            operation.terminate()
        }
        dependencyInstalls[bottle.id]?.cancel()
    }

    private func stopProcesses(_ bottle: Bottle) async throws {
        interruptOperations(in: bottle)
        // Wine returns 1 when no server holds the prefix lock. Verify the stopped
        // postcondition below rather than treating every status 1 as success.
        try await serverCommand("-k", in: bottle, timeout: 15, tolerating: 1)
        try await serverCommand("-w", in: bottle, timeout: 15)
    }

    public func run(arguments: [String], in bottle: Bottle, timeout: TimeInterval? = nil,
                    onStart: (@Sendable (LaunchStart) -> Void)? = nil) async throws -> OperationResult {
        try await execute(arguments: arguments, bottle: bottle, directory: nil, timeout: timeout, onStart: onStart,
                          log: LogName("exec", arguments.first.map { URL(fileURLWithPath: $0).lastPathComponent }))
    }

    public func configureSynchronization(msyncEnabled: Bool, in bottle: Bottle) async throws -> Bottle {
        guard !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Settings setup is already in progress for this bottle.")
        }
        settingsChanging.insert(bottle.id)
        defer { settingsChanging.remove(bottle.id) }
        let (current, launch, lifetime) = try await idleBottle(bottle)
        defer { lifetime.release(); launch.release() }
        guard supportsMSync(current.runtime) else {
            throw MagicWineError.setup("MSync requires the updated MagicWine-managed Wine runtime. Choose Update Wine in this bottle’s dashboard, or run install-wine --accept-unsigned followed by runtime upgrade in the CLI. Custom Wine is unchanged.")
        }
        try Task.checkCancellation()
        return try await store.setSynchronization(msyncEnabled: msyncEnabled, in: current)
    }

    /// Explicit adoption only: never downloads Wine or changes quarantine/trust settings.
    public func upgradeRuntime(in bottle: Bottle) async throws -> Bottle {
        guard !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Settings setup is already in progress for this bottle.")
        }
        settingsChanging.insert(bottle.id)
        defer { settingsChanging.remove(bottle.id) }
        let (current, launch, lifetime) = try await idleBottle(bottle)
        defer { lifetime.release(); launch.release() }
        guard canUpgradeRuntime(current.runtime) else {
            throw MagicWineError.setup("Only a bottle pinned to an older MagicWine-managed Metal Wine runtime can use this upgrade.")
        }
        let executable = managedExecutableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MagicWineError.setup("The updated Wine runtime is not installed. Choose Update Wine in this bottle’s dashboard to install and switch in one step, or run install-wine --accept-unsigned before retrying runtime upgrade in the CLI.")
        }
        try RuntimeInstallation.validateCachedRuntime(at: RuntimeInstallation.destination(paths: paths), paths: paths)
        try validateGraphicsRuntime(current.graphics.backend, executable: executable)
        let runtime = try await inspect(executableURL: executable)
        try Task.checkCancellation()
        return try await store.setRuntime(runtime, in: current)
    }

    private func idleBottle(_ bottle: Bottle) async throws -> (Bottle, GraphicsOperationLease, GraphicsOperationLease) {
        guard active[bottle.id]?.isEmpty != false, pendingLaunches[bottle.id]?.isEmpty != false else {
            throw MagicWineError.setup("Close this bottle's Windows programs or use Stop before changing synchronization or Wine.")
        }
        try paths.prepare()
        let launch = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                              kind: .launch, exclusive: true, timeout: .zero)
        do {
            let lifetime = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                                    kind: .lifetime, exclusive: true, timeout: .zero)
            do {
                let current = try await store.current(bottle)
                // A detached Windows child may outlive our process lease. Waiting briefly
                // observes the real server without killing it or changing its backend.
                try await serverCommand("-w", in: current, timeout: 0.5, idleProbe: true)
                return (current, launch, lifetime)
            } catch {
                lifetime.release()
                throw error
            }
        } catch {
            launch.release()
            throw error
        }
    }

    public func configureDisplay(retinaEnabled: Bool, in bottle: Bottle) async throws -> Bottle {
        guard !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Graphics or display setup is already in progress for this bottle.")
        }
        settingsChanging.insert(bottle.id)
        defer { settingsChanging.remove(bottle.id) }
        try paths.prepare()
        let launch = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                              kind: .launch, exclusive: true)
        defer { launch.release() }
        let current = try await store.current(bottle)
        guard current.isInitialized else {
            throw MagicWineError.setup("Initialize this bottle before changing its display settings.")
        }
        let configuration = DisplayConfiguration(retinaEnabled: retinaEnabled)
        if current.display == configuration, try await !store.displayNeedsUpdate(current) { return current }
        _ = try await stopProcesses(current)
        let lifetime = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                                kind: .lifetime, exclusive: true, timeout: .seconds(15))
        defer { lifetime.release() }
        try Task.checkCancellation()
        return try await store.prepareDisplay(current, configuration: configuration)
    }

    public func configureGraphics(_ backend: GraphicsBackend, in bottle: Bottle,
                                  showHUD: Bool = false, acceptExperimental: Bool = false,
                                  componentSource: URL? = nil,
                                  progress: (@Sendable (GraphicsSetupProgress) -> Void)? = nil) async throws -> Bottle {
        guard backend == .standard || acceptExperimental else {
            throw MagicWineError.setup("\(backend.displayName) is experimental third-party code. Confirm its installation before enabling it.")
        }
        guard componentSource == nil || backend == .d3dmetal else {
            throw MagicWineError.setup("A graphics library import folder is only supported for D3DMetal.")
        }
        guard !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Graphics or display setup is already in progress for this bottle.")
        }
        guard backend == .standard || !installingGraphics.contains(backend) else {
            throw MagicWineError.setup("Another \(backend.displayName) installation is in progress. Wait for it to finish before configuring another bottle.")
        }
        settingsChanging.insert(bottle.id)
        if backend != .standard { installingGraphics.insert(backend) }
        defer {
            settingsChanging.remove(bottle.id)
            installingGraphics.remove(backend)
        }
        try paths.prepare()
        let launch = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                              kind: .launch, exclusive: true)
        defer { launch.release() }
        let current = try await store.current(bottle)
        guard current.isInitialized else {
            throw MagicWineError.setup("Initialize this bottle before changing its graphics backend.")
        }
        guard backend == .standard || current.graphics.backend != backend || graphicsProviders.supports(current.graphics) else {
            throw MagicWineError.setup("This bottle uses an unsupported \(backend.displayName) component (\(current.graphics.componentID ?? "none")) that cannot be updated in place. Choose Standard to restore this bottle's original graphics files, then enable the backend again.")
        }
        let retainingComponent = backend != .standard && current.graphics.backend == backend
        var source = componentSource
        if backend == .d3dmetal {
            guard !retainingComponent || componentSource == nil else {
                throw MagicWineError.setup("Choose Standard before importing a different D3DMetal component.")
            }
            if !retainingComponent && source == nil {
                source = Self.discoverD3DMetalSource(executable: current.runtime.executableURL)
            }
            guard retainingComponent || source != nil else {
                throw MagicWineError.setup("No local D3DMetal libraries were found beside this bottle's Wine or in an installed CrossOver. Select a library folder or pass --import <folder>; MagicWine does not download or license Apple libraries for you.")
            }
        }
        try validateGraphicsRuntime(backend, executable: current.runtime.executableURL)
        progress?(.stopping)
        _ = try await stopProcesses(current)
        let lifetime = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                                kind: .lifetime, exclusive: true, timeout: .seconds(15))
        defer { lifetime.release() }
        try Task.checkCancellation()
        let componentRoot: URL?
        if retainingComponent {
            progress?(.verifying)
            componentRoot = try graphicsComponent(current.graphics).root
            let prefix = store.prefixURL(for: current)
            try GraphicsPrefix.validateInstalled(configuration: current.graphics, prefix: prefix,
                                                 bottleDirectory: prefix.deletingLastPathComponent())
        } else if let provider = graphicsProviders[backend] {
            componentRoot = try await provider.install(paths: paths, source: source, progress: progress)
        } else {
            componentRoot = nil
        }
        if let componentRoot, graphicsProviders[backend]?.viewSubstitutions.isEmpty == false {
            _ = try GraphicsRuntimeView.prepare(executable: current.runtime.executableURL,
                                                 component: componentRoot, backend: backend, paths: paths)
        }
        let configuration = GraphicsConfiguration(backend: backend, componentID: componentRoot?.lastPathComponent,
                                                   showHUD: backend != .standard && showHUD)
        try Task.checkCancellation()
        if backend == .standard { progress?(.restoring) }
        else if !retainingComponent { progress?(.installing) }
        return try await store.setGraphics(configuration, in: current, componentRoot: componentRoot)
    }

    /// Moves a bottle from a retained older component of its backend to the current bundled
    /// one in place: installs or verifies the current component, then swaps the prefix DLLs
    /// and saves the metadata in one journaled `GraphicsPrefix` transaction that keeps the
    /// pre-renderer originals. Like `configureGraphics` it needs consent and stops the
    /// bottle's processes under the exclusive launch and lifetime leases. The old component
    /// stays in `Components/` for storage cleanup. A bottle already on the current component
    /// is returned unchanged; unsupported components still require restoring Standard.
    public func updateGraphicsComponent(in bottle: Bottle, acceptExperimental: Bool = false,
                                        progress: (@Sendable (GraphicsSetupProgress) -> Void)? = nil) async throws -> Bottle {
        let backend = bottle.graphics.backend
        guard let provider = graphicsProviders[backend] else {
            throw MagicWineError.setup("Standard graphics has no component to update.")
        }
        guard let target = provider.currentComponentID else {
            throw MagicWineError.setup("\(backend.displayName) components are your imported libraries; MagicWine has no newer version to install. Choose Standard, then import the libraries again to change them.")
        }
        guard acceptExperimental else {
            throw MagicWineError.setup("\(backend.displayName) is experimental third-party code. Confirm installing \(target) before updating this bottle's component.")
        }
        guard !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Graphics or display setup is already in progress for this bottle.")
        }
        guard !installingGraphics.contains(backend) else {
            throw MagicWineError.setup("Another \(backend.displayName) installation is in progress. Wait for it to finish before configuring another bottle.")
        }
        settingsChanging.insert(bottle.id)
        installingGraphics.insert(backend)
        defer {
            settingsChanging.remove(bottle.id)
            installingGraphics.remove(backend)
        }
        try paths.prepare()
        let launch = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                              kind: .launch, exclusive: true)
        defer { launch.release() }
        let current = try await store.current(bottle)
        guard current.isInitialized, current.graphics.backend == backend else {
            throw MagicWineError.setup("This bottle's graphics backend changed. Reload it before updating its component.")
        }
        guard current.graphics.componentID != target else { return current }
        guard graphicsProviders.supports(current.graphics) else {
            throw MagicWineError.setup("This bottle uses an unsupported \(backend.displayName) component (\(current.graphics.componentID ?? "none")) that cannot be updated in place. Choose Standard to restore this bottle's original graphics files, then enable \(backend.displayName) again.")
        }
        try provider.validateRuntime(current.runtime.executableURL)
        progress?(.stopping)
        _ = try await stopProcesses(current)
        let lifetime = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                                kind: .lifetime, exclusive: true, timeout: .seconds(15))
        defer { lifetime.release() }
        try Task.checkCancellation()
        let componentRoot = try await provider.install(paths: paths, source: nil, progress: progress)
        if !provider.viewSubstitutions.isEmpty {
            _ = try GraphicsRuntimeView.prepare(executable: current.runtime.executableURL,
                                                 component: componentRoot, backend: backend, paths: paths)
        }
        var configuration = current.graphics
        configuration.componentID = componentRoot.lastPathComponent
        try Task.checkCancellation()
        progress?(.installing)
        return try await store.setGraphics(configuration, in: current, componentRoot: componentRoot, componentUpdate: true)
    }

    /// Changes only the persisted HUD preference of the current non-Standard backend.
    /// HUD is launch environment, so this never stops processes, touches prefix DLLs,
    /// or re-verifies components; running programs keep their HUD state and programs
    /// launched afterwards use the new one. The brief metadata write still excludes
    /// concurrent graphics, display, synchronization, and runtime changes.
    public func setGraphicsHUD(_ showHUD: Bool, in bottle: Bottle) async throws -> Bottle {
        guard !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Graphics or display setup is already in progress for this bottle.")
        }
        settingsChanging.insert(bottle.id)
        defer { settingsChanging.remove(bottle.id) }
        try paths.prepare()
        return try await store.setGraphicsHUD(showHUD, in: bottle)
    }

    /// Names a Windows process's log: an operation such as `launch`, plus its program.
    struct LogName {
        let operation: String
        let detail: String?
        init(_ operation: String, _ detail: String? = nil) {
            self.operation = operation
            self.detail = detail
        }
    }

    private func execute(arguments: [String], bottle: Bottle, directory: URL?, timeout: TimeInterval?,
                         onStart: (@Sendable (LaunchStart) -> Void)? = nil,
                         exitStatusIsResult: Bool = false, program: WindowsProgram? = nil,
                         diagnostics: Bool = false, log logName: LogName? = nil) async throws -> OperationResult {
        guard !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Wait for this bottle's graphics or display setup to finish before running Windows programs.")
        }
        try paths.prepare()
        let handoffID = UUID()
        let launchTask: Task<GraphicsOperationLease, Error>? = Task {
            try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id, kind: .launch, exclusive: true)
        }
        if let launchTask { pendingLaunches[bottle.id, default: [:]][handoffID] = launchTask }
        defer {
            pendingLaunches[bottle.id]?[handoffID] = nil
            if pendingLaunches[bottle.id]?.isEmpty == true { pendingLaunches[bottle.id] = nil }
        }
        let launch: GraphicsOperationLease?
        do {
            launch = try await withTaskCancellationHandler {
                try await launchTask?.value
            } onCancel: {
                launchTask?.cancel()
            }
        } catch is CancellationError {
            if Task.isCancelled { throw CancellationError() }
            throw try pendingStop(bottle)
        }
        defer { launch?.release() }
        let current = try await store.current(bottle)
        try Task.checkCancellation()
        if launchTask?.isCancelled == true { throw try pendingStop(bottle) }
        guard !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Wait for this bottle's graphics or display setup to finish before running Windows programs.")
        }
        let prefix = try prefixURL(for: current)
        // The descriptor is pinned, never fall back to whichever Wine is in PATH today.
        let wine = current.runtime.executableURL.standardizedFileURL
        try validateExecutable(wine)
        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            throw MagicWineError.runtimeUnavailable("The bottle's pinned runtime is missing \(wine.path). Select an intact Wine distribution; this bottle was not migrated.")
        }
        // Options come from the saved record; hand-edited metadata is validated again.
        let savedProgram = try program.map { requested in
            let saved = current.programs.first {
                $0.id == requested.id && $0.executablePath == requested.executablePath
            } ?? requested
            try saved.validateLaunchOptions()
            _ = try saved.launchDirectory()
            return saved
        }
        if current.isInitialized, (try? PrefixBoot.hasPendingRenames(prefix: prefix)) ?? true {
            try await bootIfIdle(current, prefix: prefix)
            try Task.checkCancellation()
            if launchTask?.isCancelled == true { throw try pendingStop(bottle) }
        }
        if try await store.displayNeedsUpdate(current) {
            // Never rewrite a live wineserver's registry or terminate a game merely
            // to adopt the new default. Explicit setting changes use Stop above.
            do {
                let displayLifetime = try await GraphicsOperationLease.acquire(
                    paths: paths, bottleID: bottle.id, kind: .lifetime, exclusive: true, timeout: .seconds(1))
                defer { displayLifetime.release() }
                try await serverCommand("-w", in: current, timeout: 15)
                try Task.checkCancellation()
                if launchTask?.isCancelled == true { throw try pendingStop(bottle) }
                _ = try await store.prepareDisplay(current)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MagicWineError.setup("Could not apply this bottle's Retina / HiDPI settings. Close its Windows programs or use Stop, then retry. \(error.localizedDescription)")
            }
        }
        let lifetime = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                                kind: .lifetime, exclusive: false)
        defer { lifetime.release() }
        try GraphicsPrefix.withLock(bottleDirectory: prefix.deletingLastPathComponent()) {
            try BottleDesktop.prepare(prefix: prefix)
        }
        var integrations: LaunchIntegrations?
        if current.isInitialized {
            let gamepad: Result<[String: String], any Error>
            do { gamepad = .success(try await GamepadService.shared.prepare(paths: paths)) }
            catch { gamepad = .failure(error) }
            // Main-actor discovery suspends this actor. Honor Stop before changing
            // prefix DLLs or spawning a process after that handoff.
            try Task.checkCancellation()
            if launchTask?.isCancelled == true { throw try pendingStop(bottle) }
            let directory = prefix.deletingLastPathComponent()
            integrations = try Self.prepareIntegrations(gamepad: gamepad, rosetta: {
                try GraphicsPrefix.withLock(bottleDirectory: directory) {
                    try RosettaCPUCompatibility.prepare(runtime: current.runtime, prefix: prefix,
                                                         bottleDirectory: directory)
                }
            }, bridge: {
                try GraphicsPrefix.withLock(bottleDirectory: directory) {
                    try GamepadBridge.prepare(prefix: prefix, bottleDirectory: directory)
                }
            })
        }
        let graphics = current.graphics.backend != .standard
            ? try prepareGraphicsLaunch(for: current, prefix: prefix) : nil
        let plan = LaunchPlanner.plan(LaunchRequest(
            inherited: ProcessInfo.processInfo.environment, runtime: runtimeFacts(for: wine),
            executable: wine, arguments: arguments, directory: directory ?? prefix, prefix: prefix,
            msyncEnabled: current.msyncEnabled, integrations: integrations, graphics: graphics,
            compatibility: current.compatibility, program: savedProgram, diagnostics: diagnostics))
        let id = UUID()
        let name = logName ?? savedProgram.map { LogName(diagnostics ? "diagnostics" : "launch", $0.name) } ?? LogName("exec")
        let log = try ProcessLogFile.create(in: ProcessLogs.bottleDirectory(bottle.id, paths: paths),
                                            operation: name.operation, detail: name.detail)
        let operation = ProcessOperation(executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, directory: plan.directory,
            output: .log(log), timeout: timeout, warnings: plan.warnings, exitStatusIsResult: exitStatusIsResult)
        active[bottle.id, default: [:]][id] = operation
        defer {
            active[bottle.id]?[id] = nil
            if active[bottle.id]?.isEmpty == true { active[bottle.id] = nil }
        }
        let started = LaunchStart(logURL: log.url, warnings: plan.warnings)
        do {
            return try await operation.run(onStart: {
                launch?.release()
                onStart?(started)
            })
        } catch is CancellationError {
            await cleanup(bottle)
            throw CancellationError()
        } catch ProcessOperation.Interrupted.timedOut(let log) {
            await cleanup(bottle)
            throw MagicWineError.setup("Wine operation timed out. Log: \(log.path)")
        }
    }

    /// Runs the bottle's pinned `wineserver` with `-k` or `-w`. Server commands bypass
    /// launch preparation and leases so Stop and idle checks work while a mutation holds
    /// the launch lease, and they use only the base environment layer. Their output stays
    /// in memory and becomes a bottle log only when they fail, time out, or are stopped.
    private func serverCommand(_ argument: String, in bottle: Bottle, timeout: TimeInterval?,
                               tracked: Bool = false, idleProbe: Bool = false, tolerating tolerated: Int32? = nil,
                               stoppedLog: URL? = nil) async throws {
        try paths.prepare()
        let current = try await store.current(bottle)
        let prefix = try prefixURL(for: current)
        // The descriptor is pinned, never fall back to whichever Wine is in PATH today.
        let wine = current.runtime.executableURL.standardizedFileURL
        try validateExecutable(wine)
        let server = wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        guard FileManager.default.isExecutableFile(atPath: server.path) else {
            throw MagicWineError.runtimeUnavailable("The bottle's pinned runtime is missing \(server.path). Select an intact Wine distribution; this bottle was not migrated.")
        }
        let plan = LaunchPlanner.plan(LaunchRequest(
            inherited: ProcessInfo.processInfo.environment, runtime: runtimeFacts(for: wine),
            executable: server, arguments: [argument], directory: prefix, prefix: prefix,
            msyncEnabled: current.msyncEnabled))
        let id = UUID()
        let operation = ProcessOperation(executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, directory: plan.directory,
            output: .probe(directory: ProcessLogs.bottleDirectory(bottle.id, paths: paths), operation: "wineserver",
                           detail: argument, stoppedLog: stoppedLog),
            timeout: timeout, exitStatusIsResult: true)
        if tracked { active[bottle.id, default: [:]][id] = operation }
        defer {
            if tracked {
                active[bottle.id]?[id] = nil
                if active[bottle.id]?.isEmpty == true { active[bottle.id] = nil }
            }
        }
        let status: Int32
        do {
            status = try await operation.probe().status
        } catch is CancellationError {
            if tracked { await cleanup(bottle) }
            throw CancellationError()
        } catch ProcessOperation.Interrupted.timedOut(let log) {
            if tracked { await cleanup(bottle) }
            if idleProbe {
                throw MagicWineError.setup("This bottle's Wine server is still running. Close its Windows programs or use Stop before changing synchronization or Wine. Log: \(log.path)")
            }
            throw MagicWineError.setup("Wine operation timed out. Log: \(log.path)")
        }
        guard status == 0 || status == tolerated else {
            throw MagicWineError.processFailed(exitCode: status, logURL: try operation.recordProbeLog(note: "Exited with status \(status)."))
        }
    }

    /// Launch-time compatibility integrations that must never prevent a program from
    /// starting. A failed step skips only its own component, with a deterministic load
    /// order and a warning; cancellation and Stop still propagate. Both prefix steps
    /// validate everything before mutating and publish only through atomic renames.
    internal static func prepareIntegrations(gamepad: Result<[String: String], any Error>,
                                             rosetta: () throws -> Bool,
                                             bridge: () throws -> String) throws -> LaunchIntegrations {
        var result = LaunchIntegrations()
        do {
            if try rosetta() { try result.overrides.set(.native, for: "wow64cpu") }
        } catch let error where !isInterruption(error) {
            // Without an override Wine loads its builtin system CPU module.
            result.warnings.append("Rosetta CPU compatibility was skipped for this launch: \(error.localizedDescription) Wine's builtin wow64cpu.dll is used instead; some 32-bit programs may crash under Rosetta.")
        }
        do {
            // A controller service failure also skips the bridge so the prefix is not
            // changed for a component that could not run.
            let environment = try gamepad.get()
            result.overrides = result.overrides.layered(with: try DLLOverrides(parsing: bridge()))
            result.environment = environment
        } catch let error where !isInterruption(error) {
            result.overrides = result.overrides.layered(with: try DLLOverrides(parsing: GamepadBridge.builtinOverrides))
            result.warnings.append("MagicWine controller support was skipped for this launch: \(error.localizedDescription) Wine's builtin XInput is used instead, so saved controller profiles do not apply.")
        }
        return result
    }

    private static func isInterruption(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case .stopped? = error as? MagicWineError { return true }
        return false
    }

    /// Applies DLL moves Wine deferred to its next session before launch preparation
    /// replaces prefix DLLs (Rosetta `wow64cpu.dll`, XInput bridge); otherwise the launch's
    /// new session would overwrite them while the launch still loads them as native. Only an
    /// idle bottle is booted: a live session never reboots, so a running program is never
    /// waited on or stopped for this. The caller holds the exclusive launch lease.
    private func bootIfIdle(_ bottle: Bottle, prefix: URL) async throws {
        let lifetime: GraphicsOperationLease
        do {
            lifetime = try await GraphicsOperationLease.acquire(
                paths: paths, bottleID: bottle.id, kind: .lifetime, exclusive: true, timeout: .seconds(1))
        } catch let error where !Self.isInterruption(error) {
            return
        }
        defer { lifetime.release() }
        do {
            // A server lingering after its last program exits is still a live session.
            try await serverCommand("-w", in: bottle, timeout: 15)
        } catch let error where !Self.isInterruption(error) {
            return
        }
        do {
            try await completePendingBoot(bottle, prefix: prefix, deadline: Date().addingTimeInterval(180))
        } catch let error where !Self.isInterruption(error) {
            throw MagicWineError.setup("Wine could not finish this bottle's pending prefix update before the launch. Close its Windows programs or use Stop, then retry. \(error.localizedDescription)")
        }
    }

    /// With no wineserver for the prefix, one `wineboot --init` session applies every
    /// pending move (the same boot Wine runs at the start of the next session) and waits
    /// for that server to exit. An unreadable registry is left to Wine as before.
    private func completePendingBoot(_ bottle: Bottle, prefix: URL, deadline: Date) async throws {
        guard (try? PrefixBoot.hasPendingRenames(prefix: prefix)) == true else { return }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            await cleanup(bottle)
            throw MagicWineError.setup("Wine's pending prefix update timed out.")
        }
        let wine = bottle.runtime.executableURL.standardizedFileURL
        let plan = LaunchPlanner.plan(LaunchRequest(
            inherited: ProcessInfo.processInfo.environment, runtime: runtimeFacts(for: wine),
            executable: wine, arguments: ["wineboot", "--init"], directory: prefix, prefix: prefix,
            msyncEnabled: bottle.msyncEnabled))
        // A probe: its output becomes a bottle log only if the boot fails or times out.
        let operation = ProcessOperation(executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, directory: plan.directory,
            output: .probe(directory: ProcessLogs.bottleDirectory(bottle.id, paths: paths), operation: "wineboot",
                           detail: "--init"),
            timeout: remaining)
        let id = UUID()
        active[bottle.id, default: [:]][id] = operation
        defer {
            active[bottle.id]?[id] = nil
            if active[bottle.id]?.isEmpty == true { active[bottle.id] = nil }
        }
        do {
            _ = try await operation.probe()
        } catch is CancellationError {
            await cleanup(bottle)
            throw CancellationError()
        } catch ProcessOperation.Interrupted.timedOut(let log) {
            await cleanup(bottle)
            throw MagicWineError.setup("Wine's pending prefix update timed out. Log: \(log.path)")
        }
        try await serverCommand("-w", in: bottle, timeout: max(deadline.timeIntervalSinceNow, 1), tracked: true)
    }

    private func pendingStop(_ bottle: Bottle) throws -> MagicWineError {
        let log = try ProcessLogFile.record(Data("Stop requested before the Windows process started.\n".utf8),
                                            in: ProcessLogs.bottleDirectory(bottle.id, paths: paths), operation: "stopped")
        return .stopped(logURL: log)
    }

    private func cleanup(_ bottle: Bottle) async {
        // Cleanup must run even when the initiating task was cancelled.
        let task = Task.detached { [self] in
            try? await self.serverCommand("-k", in: bottle, timeout: 10, tolerating: 1)
        }
        await task.value
    }

    internal nonisolated func environment(executable: URL, prefix: URL?, msyncEnabled: Bool = true,
                                         inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        LaunchPlanner.plan(LaunchRequest(inherited: inherited, runtime: runtimeFacts(for: executable),
                                         executable: executable, arguments: [], directory: nil, prefix: prefix,
                                         msyncEnabled: msyncEnabled)).environment
    }

    /// Managed capabilities follow the canonical executable location, never a version label.
    internal nonisolated func runtimeFacts(for executable: URL) -> LaunchRuntimeFacts {
        let managedMetalRoot = paths.runtimesDirectory.resolvingSymlinksInPath().standardizedFileURL.path +
            "/wine-\(RuntimeInstallation.version)-\(RuntimeInstallation.archiveSHA256.prefix(12))-winemac-wine11.0-metal."
        let selectedPath = executable.resolvingSymlinksInPath().standardizedFileURL.path
        return LaunchRuntimeFacts(
            managedMSync: supportsMSync(RuntimeDescriptor(executableURL: executable, version: "")),
            managedMetal: selectedPath.hasPrefix(managedMetalRoot) &&
                selectedPath.hasSuffix("/" + RuntimeInstallation.relativeExecutable),
            rosettaAVX: rosettaAVXAvailability(RuntimeDescriptor(executableURL: executable, version: "")) == .available)
    }

    /// Apple's Game Porting Toolkit documents `ROSETTA_ADVERTISE_AVX=1` for Rosetta 2 on
    /// macOS 15 and later. It only affects x86_64 code translated by Rosetta, so native
    /// arm64 Wine (or an Intel Mac) cannot use it.
    public nonisolated func rosettaAVXAvailability(_ runtime: RuntimeDescriptor) -> RosettaAVXAvailability {
        #if arch(arm64)
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)) else {
            return .unavailable(reason: "Rosetta AVX advertising requires macOS 15 or later.")
        }
        guard (try? requiresRosetta(runtime.executableURL.resolvingSymlinksInPath())) == true else {
            return .unavailable(reason: "This bottle's Wine does not run under Rosetta 2, so Rosetta cannot advertise AVX to it.")
        }
        return .available
        #else
        return .unavailable(reason: "Rosetta AVX advertising applies only on Apple silicon Macs.")
        #endif
    }

    /// Backend wiring for this runtime. Prefix footprints stay the bundled providers'
    /// (`GraphicsPrefix`), so a substitute must keep its backend's mappings.
    private var graphicsProviders = GraphicsComponentProviders.bundled

    /// Tests substitute fixture components with their own pins.
    internal func useGraphicsProviders(_ providers: GraphicsComponentProviders) {
        graphicsProviders = providers
    }

    private func validateGraphicsRuntime(_ backend: GraphicsBackend, executable: URL) throws {
        try graphicsProviders[backend]?.validateRuntime(executable)
    }

    private func graphicsComponent(_ configuration: GraphicsConfiguration) throws -> (provider: any GraphicsComponentProvider, root: URL) {
        guard let componentID = configuration.componentID else {
            throw MagicWineError.setup("This bottle has no pinned \(configuration.backend.displayName) component. Choose Standard to restore its original graphics files, then enable the backend again.")
        }
        guard let provider = graphicsProviders[configuration.backend] else {
            throw MagicWineError.setup("Standard graphics does not use a graphics component.")
        }
        return (provider, try provider.validate(componentID: componentID, paths: paths))
    }

    /// Validates the pinned component and installed footprint, creates the bottle's
    /// graphics folders, and prepares a Metal backend's private runtime view.
    private func prepareGraphicsLaunch(for bottle: Bottle, prefix: URL) throws -> GraphicsLaunchFacts {
        let (provider, component) = try graphicsComponent(bottle.graphics)
        try provider.validateRuntime(bottle.runtime.executableURL)
        let directory = prefix.deletingLastPathComponent()
        try GraphicsPrefix.validateInstalled(configuration: bottle.graphics, prefix: prefix, bottleDirectory: directory)
        let folders = try provider.cacheFolder.map { try graphicsDirectories(for: bottle, directory: directory, cache: $0) }
        let loader = provider.viewSubstitutions.isEmpty ? nil
            : try GraphicsRuntimeView.prepare(executable: bottle.runtime.executableURL,
                                              component: component, backend: provider.backend, paths: paths)
        return try provider.launchFacts(component: component, showHUD: bottle.graphics.showHUD, folders: folders,
                                        loader: loader,
                                        server: bottle.runtime.executableURL.deletingLastPathComponent().appendingPathComponent("wineserver"))
    }

    private func graphicsDirectories(for bottle: Bottle, directory: URL, cache: String) throws -> GraphicsFolders {
        let backend = bottle.graphics.backend
        let cache = directory.appendingPathComponent(cache, isDirectory: true)
        let logs = ProcessLogs.bottleDirectory(bottle.id, paths: paths).appendingPathComponent(backend.rawValue, isDirectory: true)
        for folder in [cache, logs] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let attributes = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else {
                throw MagicWineError.setup("The graphics cache/log directory must not be a symbolic link: \(folder.path)")
            }
        }
        return GraphicsFolders(cache: cache, logs: logs)
    }

    private func prefixURL(for bottle: Bottle) throws -> URL {
        let prefix = paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
            .appendingPathComponent("prefix", isDirectory: true)
        var directory: ObjCBool = false
        let root = paths.bottlesDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard FileManager.default.fileExists(atPath: prefix.path, isDirectory: &directory), directory.boolValue,
              prefix.resolvingSymlinksInPath().standardizedFileURL.path == root + bottle.id.uuidString + "/prefix" else {
            throw MagicWineError.invalidBottle
        }
        return prefix
    }

    private func windowsFile(_ url: URL, extensions: Set<String>) throws -> URL {
        let file = url.standardizedFileURL
        var directory: ObjCBool = false
        guard file.isFileURL, extensions.contains(file.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: file.path, isDirectory: &directory), !directory.boolValue else {
            throw MagicWineError.invalidProgram(file.path)
        }
        return file
    }

    private func validateExecutable(_ executable: URL) throws {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MagicWineError.runtimeUnavailable("The pinned Wine executable is missing or not executable: \(executable.path)")
        }
        #if arch(arm64)
        if try requiresRosetta(executable),
           !FileManager.default.fileExists(atPath: "/Library/Apple/usr/libexec/oah/libRosettaRuntime") {
            throw MagicWineError.runtimeUnavailable("This x86_64 Wine build requires Rosetta. Install Rosetta through Apple's macOS prompt or run /usr/sbin/softwareupdate --install-rosetta in Terminal and review Apple's license yourself. MagicWine will not accept it for you.")
        }
        #endif
    }

    private nonisolated func requiresRosetta(_ executable: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        let cpus = MachOInspector.cpuTypes(in: try handle.read(upToCount: 4096) ?? Data()) ?? []
        return cpus.contains(MachOInspector.x86_64) && !cpus.contains(MachOInspector.arm64)
    }

    private func isReferenceRuntime(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("/crossover.app/") || path.contains("/whisky.app/") ||
               path.contains("/application support/com.isaacmarovitz.whisky/") || path.contains("/whisky/")
    }

    // MARK: - Windows dependencies

    private var dependencyInstalls: [UUID: Task<DependencyInstallResult, Error>] = [:]

    /// Each catalog item's post-install checks against the prefix files. Registry checks read
    /// Wine's saved registry, which a running Wine may not have written yet.
    public func dependencyStatus(in bottle: Bottle) async throws -> [DependencyStatus] {
        let current = try await store.current(bottle)
        let prefix = try prefixURL(for: current)
        return DependencyCatalog.items.map { item in
            DependencyInstaller.status(of: item, prefix: prefix, record: current.dependencies.last { $0.id == item.id })
        }
    }

    /// Installs catalog items in catalog order as one exclusive, stoppable bottle operation.
    /// `acceptLicense` records that the user accepted every requested item's license. Pinned
    /// downloads are cached under `Components/dependencies` and verified before every use;
    /// items whose checks already pass are skipped. Success requires the post-install checks.
    public func installDependencies(_ ids: [String], in bottle: Bottle, acceptLicense: Bool,
                                    progress: (@Sendable (DependencyProgress) -> Void)? = nil) async throws -> DependencyInstallResult {
        let requested = Set(ids)
        let items = DependencyCatalog.items.filter { requested.contains($0.id) }
        guard !requested.isEmpty, items.count == requested.count else {
            let unknown = requested.subtracting(DependencyCatalog.items.map(\.id)).sorted()
            throw MagicWineError.setup(requested.isEmpty ? "Choose at least one dependency to install."
                                       : "Unknown dependency: \(unknown.joined(separator: ", ")).")
        }
        guard acceptLicense else {
            let terms = items.map { "\($0.name): \($0.license.name) (\($0.license.url.absoluteString))" }
            throw MagicWineError.setup("Installing these dependencies requires accepting their licenses:\n" + terms.joined(separator: "\n"))
        }
        guard !settingsChanging.contains(bottle.id), dependencyInstalls[bottle.id] == nil else {
            throw MagicWineError.setup("Wait for this bottle's current setup to finish before installing dependencies.")
        }
        try paths.prepare()
        // Held open for the whole installation so retention never removes it meanwhile.
        let log = try ProcessLogFile.create(in: ProcessLogs.bottleDirectory(bottle.id, paths: paths),
                                            operation: "dependencies", detail: items.map(\.id).joined(separator: " "))
        defer { log.close() }
        progress?(.started(logURL: log.url))
        // Stop cancels this task through interruptOperations, like a pending launch.
        let work = Task { try await self.performDependencyInstall(items, in: bottle, log: log, progress: progress) }
        dependencyInstalls[bottle.id] = work
        defer { dependencyInstalls[bottle.id] = nil }
        do {
            return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        } catch {
            if Task.isCancelled {
                Self.note("Installation cancelled.", in: log)
                throw CancellationError()
            }
            if error is CancellationError {
                Self.note("Stopped.", in: log)
                throw MagicWineError.stopped(logURL: log.url)
            }
            if case .stopped? = error as? MagicWineError { throw error }
            Self.note("Failure: \(error.localizedDescription)", in: log)
            throw MagicWineError.setup("\(error.localizedDescription)\nDependency log: \(log.url.path)")
        }
    }

    private func performDependencyInstall(_ items: [DependencyItem], in bottle: Bottle, log: ProcessLogFile,
                                          progress: (@Sendable (DependencyProgress) -> Void)?) async throws -> DependencyInstallResult {
        var current = try await store.current(bottle)
        guard current.isInitialized else {
            throw MagicWineError.setup("Initialize this bottle before installing dependencies.")
        }
        let prefix = try prefixURL(for: current)
        for item in items {
            Self.note("License accepted for \(item.name) \(item.version): \(item.license.name) \(item.license.url.absoluteString)", in: log)
        }
        try await withIdleBottleForDependencies(current, log: log) { }
        var installed: [String] = []
        var present: [String] = []
        for item in items {
            try Task.checkCancellation()
            if DependencyInstaller.status(of: item, prefix: prefix, record: nil).isInstalled {
                Self.note("\(item.id): already present; nothing changed.", in: log)
                present.append(item.id)
                continue
            }
            var downloads: [URL] = []
            for download in item.downloads {
                progress?(.downloading(id: item.id, WineDownloadProgress(receivedBytes: 0, totalBytes: download.size)))
                let file = try await DependencyInstaller.cachedDownload(download, of: item, paths: paths, progress: { update in
                    progress?(.downloading(id: item.id, update))
                })
                Self.note("\(item.id): verified \(download.url.absoluteString) SHA-256 \(download.sha256) at \(file.path)", in: log)
                downloads.append(file)
            }
            progress?(.verifying(id: item.id))
            progress?(.installing(id: item.id))
            let stage = DependencyInstaller.cacheDirectory(paths: paths)
                .appendingPathComponent(".extract-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stage) }
            var extracted: [DependencyFile: URL] = [:]
            for step in DependencyInstaller.steps(for: item) {
                try Task.checkCancellation()
                switch step {
                case .runInstaller(let index, let arguments):
                    // Verified again immediately before Wine executes it.
                    let installer = try await DependencyInstaller.cachedDownload(item.downloads[index], of: item, paths: paths)
                    let result = try await execute(arguments: [installer.path] + arguments, bottle: current,
                                                   directory: installer.deletingLastPathComponent(), timeout: 1800,
                                                   exitStatusIsResult: true, log: LogName("dependency", installer.lastPathComponent))
                    // Installers report success-with-restart and similar as nonzero; the checks decide.
                    Self.note("\(item.id): \(installer.lastPathComponent) exited with code \(result.exitCode). Log: \(result.logURL.path)", in: log)
                    try await waitForDependencyWine(current)
                case .extract(let index, let members):
                    if !FileManager.default.fileExists(atPath: stage.path) {
                        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                                attributes: [.posixPermissions: 0o700])
                    }
                    guard case .files(let files) = item.method else { continue }
                    let wanted = files.filter { $0.download == index && members.contains($0.member) }
                    let output = try await DependencyInstaller.extract(wanted, from: downloads[index],
                        into: stage.appendingPathComponent(String(index), isDirectory: true), paths: paths)
                    extracted.merge(output) { $1 }
                case .place(let files):
                    let sources = extracted.filter { files.contains($0.key) }
                    guard sources.count == files.count else {
                        throw MagicWineError.setup("\(item.name): not every file was extracted.")
                    }
                    try await withIdleBottleForDependencies(current, log: log) {
                        try GraphicsPrefix.withLock(bottleDirectory: prefix.deletingLastPathComponent()) {
                            try DependencyInstaller.place(sources, prefix: prefix)
                        }
                    }
                    Self.note("\(item.id): placed \(files.map(\.destination).joined(separator: ", ")) below drive_c/windows.", in: log)
                case .importRegistry(let text):
                    let temp = prefix.appendingPathComponent("drive_c/windows/temp", isDirectory: true)
                    try DependencyInstaller.fs.requireDirectory(temp)
                    let name = "magicwine-dependencies-\(UUID().uuidString).reg"
                    let file = temp.appendingPathComponent(name)
                    try Data(text.utf8).write(to: file, options: .withoutOverwriting)
                    defer { try? FileManager.default.removeItem(at: file) }
                    let result = try await execute(arguments: ["reg", "import", #"C:\windows\temp\"# + name], bottle: current,
                                                   directory: nil, timeout: 120, log: LogName("dependency", "\(item.id) registry"))
                    Self.note("\(item.id): imported registry values. Log: \(result.logURL.path)\n\(text)", in: log)
                    try await waitForDependencyWine(current)
                }
            }
            progress?(.checking(id: item.id))
            let status = DependencyInstaller.status(of: item, prefix: prefix, record: nil)
            guard status.isInstalled else {
                throw MagicWineError.setup("\(item.name) did not pass its post-install check. Missing: \(status.missing.prefix(6).joined(separator: ", "))\(status.missing.count > 6 ? ", …" : "").")
            }
            // Whole seconds round-trip exactly through bottle.json, so later saves compare equal.
            let installedAt = Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
            current = try await store.recordDependency(InstalledDependency(id: item.id, version: item.version, installedAt: installedAt),
                                                       in: current)
            Self.note("\(item.id): post-install check passed.", in: log)
            installed.append(item.id)
        }
        return DependencyInstallResult(bottle: current, logURL: log.url, installed: installed, alreadyPresent: present)
    }

    /// Waits for every Wine process of the bottle, including installer children, so the
    /// registry is saved before checks run and files are only placed in an idle prefix.
    private func waitForDependencyWine(_ bottle: Bottle) async throws {
        try await serverCommand("-w", in: bottle, timeout: 600, tracked: true)
    }

    /// Runs `body` while holding exclusive launch and lifetime leases of an idle bottle.
    private func withIdleBottleForDependencies(_ bottle: Bottle, log: ProcessLogFile, _ body: () throws -> Void) async throws {
        if active[bottle.id]?.isEmpty != false, pendingLaunches[bottle.id]?.isEmpty != false {
            // Wine's server outlives the last program by a few seconds. Wait for it briefly
            // (untracked, so a timeout never kills anything) instead of refusing at once.
            try? await serverCommand("-w", in: bottle, timeout: 15)
            try Task.checkCancellation()
        }
        let launch: GraphicsOperationLease
        let lifetime: GraphicsOperationLease
        do {
            (_, launch, lifetime) = try await idleBottle(bottle)
        } catch MagicWineError.setup(let detail) {
            Self.note("Bottle not idle: \(detail)", in: log)
            throw MagicWineError.setup("Close this bottle's Windows programs or use Stop before installing dependencies.")
        }
        defer { lifetime.release(); launch.release() }
        try body()
    }

    private static func note(_ text: String, in log: ProcessLogFile) {
        log.write(Data((text + "\n").utf8))
    }
}

/// Process-local result of `WineRuntime.prepareIntegrations`, layered in order.
internal struct LaunchIntegrations: Sendable {
    var overrides = DLLOverrides()
    var environment: [String: String] = [:]
    var warnings: [String] = []
}
