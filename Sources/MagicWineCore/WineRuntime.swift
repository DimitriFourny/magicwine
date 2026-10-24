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

    public init(paths: ApplicationPaths) {
        self.paths = paths
        store = BottleStore(paths: paths)
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
        let log = logURL(name: "wine-version")
        let operation = ProcessOperation(executable: executable, arguments: ["--version"],
            environment: environment(executable: executable, prefix: nil), directory: nil, logURL: log, timeout: 15)
        do { _ = try await operation.run() }
        catch ProcessOperation.Interrupted.timedOut(let log) {
            throw MagicWineError.runtimeUnavailable("Wine version inspection timed out for \(executable.path). If macOS is blocking a custom Wine installation, review System Settings > Privacy & Security. For managed Wine, run Install / Update Wine again and accept the unsigned-runtime confirmation. Log: \(log.path)")
        }
        let text = try RuntimeInstallation.boundedLog(log)
        guard let version = text.components(separatedBy: .newlines).dropFirst(2)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.lowercased().hasPrefix("wine-") || $0.lowercased().hasPrefix("wine ") }),
              version.count <= 256 else {
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

    public func initialize(_ bottle: Bottle) async throws -> OperationResult {
        let deadline = Date().addingTimeInterval(180)
        let result = try await execute(arguments: ["wineboot", "-u"], bottle: bottle,
                                       directory: nil, timeout: 180)
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            await cleanup(bottle)
            throw MagicWineError.setup("Bottle setup timed out. Log: \(result.logURL.path)")
        }
        _ = try await execute(arguments: ["-w"], bottle: bottle, directory: nil,
                              timeout: remaining, server: true)
        let prefix = try prefixURL(for: bottle)
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
              FileManager.default.fileExists(atPath: prefix.appendingPathComponent("user.reg").path) else {
            throw MagicWineError.setup("Wine exited without creating the bottle registry. Setup log: \(result.logURL.path)")
        }
        return result
    }

    public func install(_ installerURL: URL, in bottle: Bottle) async throws -> OperationResult {
        let installer = try windowsFile(installerURL, extensions: ["exe", "msi"])
        let arguments = installer.pathExtension.lowercased() == "msi"
            ? ["msiexec", "/i", installer.path] : [installer.path]
        return try await execute(arguments: arguments, bottle: bottle,
                                 directory: installer.deletingLastPathComponent(), timeout: nil)
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
            _ = try await execute(arguments: ["-w"], bottle: bottle, directory: nil,
                                  timeout: nil, server: true)
        }
        return result
    }

    public func configure(_ bottle: Bottle) async throws -> OperationResult {
        try await execute(arguments: ["winecfg"], bottle: bottle, directory: nil, timeout: nil)
    }

    public func stop(_ bottle: Bottle) async throws -> OperationResult {
        interruptOperations(in: bottle)
        try paths.prepare()
        let launch = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                              kind: .launch, exclusive: true)
        defer { launch.release() }
        let result = try await stopProcesses(bottle)
        let lifetime = try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                                kind: .lifetime, exclusive: true, timeout: .seconds(15))
        lifetime.release()
        return result
    }

    private func interruptOperations(in bottle: Bottle) {
        for pending in pendingLaunches[bottle.id]?.values ?? Dictionary<UUID, Task<GraphicsOperationLease, Error>>().values {
            pending.cancel()
        }
        for operation in active[bottle.id]?.values ?? Dictionary<UUID, ProcessOperation>().values {
            operation.terminate()
        }
    }

    private func stopProcesses(_ bottle: Bottle) async throws -> OperationResult {
        interruptOperations(in: bottle)
        let result: OperationResult
        do {
            result = try await execute(arguments: ["-k"], bottle: bottle, directory: nil,
                                       timeout: 15, server: true, tracked: false)
        } catch MagicWineError.processFailed(let code, let log) where code == 1 {
            // Wine returns 1 when no server holds the prefix lock. Verify the stopped
            // postcondition below rather than treating every status 1 as success.
            result = OperationResult(exitCode: code, logURL: log)
        }
        _ = try await execute(arguments: ["-w"], bottle: bottle, directory: nil,
                              timeout: 15, server: true, tracked: false)
        return result
    }

    public func run(arguments: [String], in bottle: Bottle, timeout: TimeInterval? = nil,
                    onStart: (@Sendable (LaunchStart) -> Void)? = nil) async throws -> OperationResult {
        try await execute(arguments: arguments, bottle: bottle, directory: nil, timeout: timeout, onStart: onStart)
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
                _ = try await execute(arguments: ["-w"], bottle: current, directory: nil,
                                      timeout: 0.5, server: true, tracked: false, idleProbe: true)
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
        guard backend == .standard || current.graphics.backend != backend || current.graphics.usesCurrentComponent else {
            throw MagicWineError.setup("In-place \(backend.displayName) component updates are not supported. Choose Standard to restore this bottle's original graphics files, then enable the backend again.")
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
            componentRoot = try graphicsComponent(current.graphics)
            let prefix = store.prefixURL(for: current)
            try GraphicsPrefix.validateInstalled(configuration: current.graphics, prefix: prefix,
                                                 bottleDirectory: prefix.deletingLastPathComponent())
        } else {
            switch backend {
            case .standard: componentRoot = nil
            case .dxvk: componentRoot = try await DXVKInstallation.install(paths: paths, progress: progress)
            case .dxmt: componentRoot = try await DXMTInstallation.install(paths: paths, progress: progress)
            case .d3dmetal:
                guard let source else { throw MagicWineError.setup("Select a D3DMetal library folder.") }
                componentRoot = try await D3DMetalInstallation.install(paths: paths, source: source, progress: progress)
            }
        }
        if let componentRoot, backend == .dxmt || backend == .d3dmetal {
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

    private func execute(arguments: [String], bottle: Bottle, directory: URL?, timeout: TimeInterval?,
                         server: Bool = false, tracked: Bool = true, idleProbe: Bool = false,
                         onStart: (@Sendable (LaunchStart) -> Void)? = nil,
                         exitStatusIsResult: Bool = false, program: WindowsProgram? = nil,
                         diagnostics: Bool = false) async throws -> OperationResult {
        guard server || !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Wait for this bottle's graphics or display setup to finish before running Windows programs.")
        }
        try paths.prepare()
        let handoffID = UUID()
        let launchTask: Task<GraphicsOperationLease, Error>? = server ? nil : Task {
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
        guard server || !settingsChanging.contains(bottle.id) else {
            throw MagicWineError.setup("Wait for this bottle's graphics or display setup to finish before running Windows programs.")
        }
        let prefix = try prefixURL(for: current)
        // The descriptor is pinned, never fall back to whichever Wine is in PATH today.
        let wine = current.runtime.executableURL.standardizedFileURL
        try validateExecutable(wine)
        let executable = server ? wine.deletingLastPathComponent().appendingPathComponent("wineserver") : wine
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MagicWineError.runtimeUnavailable("The bottle's pinned runtime is missing \(executable.path). Select an intact Wine distribution; this bottle was not migrated.")
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
        if !server, try await store.displayNeedsUpdate(current) {
            // Never rewrite a live wineserver's registry or terminate a game merely
            // to adopt the new default. Explicit setting changes use Stop above.
            do {
                let displayLifetime = try await GraphicsOperationLease.acquire(
                    paths: paths, bottleID: bottle.id, kind: .lifetime, exclusive: true, timeout: .seconds(1))
                defer { displayLifetime.release() }
                _ = try await execute(arguments: ["-w"], bottle: current, directory: nil,
                                      timeout: 15, server: true, tracked: false)
                try Task.checkCancellation()
                if launchTask?.isCancelled == true { throw try pendingStop(bottle) }
                _ = try await store.prepareDisplay(current)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MagicWineError.setup("Could not apply this bottle's Retina / HiDPI settings. Close its Windows programs or use Stop, then retry. \(error.localizedDescription)")
            }
        }
        let lifetime = server ? nil : try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id,
                                                                               kind: .lifetime, exclusive: false)
        defer { lifetime?.release() }
        if !server {
            try GraphicsPrefix.withLock(bottleDirectory: prefix.deletingLastPathComponent()) {
                try BottleDesktop.prepare(prefix: prefix)
            }
        }
        var integrations: LaunchIntegrations?
        if !server, current.isInitialized {
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
        let graphics = !server && current.graphics.backend != .standard
            ? try prepareGraphicsLaunch(for: current, prefix: prefix) : nil
        let plan = LaunchPlanner.plan(LaunchRequest(
            inherited: ProcessInfo.processInfo.environment, runtime: runtimeFacts(for: wine),
            executable: executable, arguments: arguments, directory: directory ?? prefix, prefix: prefix,
            msyncEnabled: current.msyncEnabled, integrations: integrations, graphics: graphics,
            compatibility: server ? nil : current.compatibility, program: savedProgram, diagnostics: diagnostics))
        let id = UUID()
        let log = logURL(name: "\(bottle.id.uuidString)-\(server ? "wineserver" : "wine")")
        let operation = ProcessOperation(executable: plan.executable, arguments: plan.arguments,
            environment: plan.environment, directory: plan.directory,
            logURL: log, timeout: timeout, warnings: plan.warnings, exitStatusIsResult: exitStatusIsResult)
        if tracked { active[bottle.id, default: [:]][id] = operation }
        defer {
            if tracked {
                active[bottle.id]?[id] = nil
                if active[bottle.id]?.isEmpty == true { active[bottle.id] = nil }
            }
        }
        let started = LaunchStart(logURL: log, warnings: plan.warnings)
        do {
            return try await operation.run(onStart: {
                launch?.release()
                onStart?(started)
            })
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

    private func pendingStop(_ bottle: Bottle) throws -> MagicWineError {
        let log = logURL(name: "\(bottle.id.uuidString)-not-started")
        try Data("Stop requested before the Windows process started.\n".utf8).write(to: log, options: .atomic)
        return .stopped(logURL: log)
    }

    private func cleanup(_ bottle: Bottle) async {
        // Cleanup must run even when the initiating task was cancelled.
        let task = Task.detached { [self] in
            _ = try? await self.execute(arguments: ["-k"], bottle: bottle, directory: nil,
                                       timeout: 10, server: true, tracked: false)
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

    private func validateVulkanRuntime(_ executable: URL) throws {
        let root = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.appendingPathComponent("lib/libMoltenVK.dylib").path),
              manager.fileExists(atPath: root.appendingPathComponent("lib/wine/x86_64-unix/winevulkan.so").path) else {
            throw MagicWineError.setup("This Wine installation does not provide the Vulkan/MoltenVK layout required by this experimental DXVK backend. Use MagicWine's managed Wine runtime or keep Standard rendering.")
        }
    }

    private func validateGraphicsRuntime(_ backend: GraphicsBackend, executable: URL) throws {
        switch backend {
        case .standard: break
        case .dxvk: try validateVulkanRuntime(executable)
        case .dxmt: try DXMTInstallation.validateRuntime(executable)
        case .d3dmetal: try D3DMetalInstallation.validateRuntime(executable)
        }
    }

    private func graphicsComponent(_ configuration: GraphicsConfiguration) throws -> URL {
        guard let componentID = configuration.componentID else {
            throw MagicWineError.setup("This bottle has no pinned \(configuration.backend.displayName) component. Choose Standard to restore its original graphics files, then enable the backend again.")
        }
        switch configuration.backend {
        case .standard: throw MagicWineError.setup("Standard graphics does not use a graphics component.")
        case .dxvk: return try DXVKInstallation.validate(componentID: componentID, paths: paths)
        case .dxmt: return try DXMTInstallation.validate(componentID: componentID, paths: paths)
        case .d3dmetal: return try D3DMetalInstallation.validate(componentID: componentID, paths: paths)
        }
    }

    /// Validates the pinned component and installed footprint, creates the bottle's
    /// graphics folders, and prepares a Metal backend's private runtime view.
    private func prepareGraphicsLaunch(for bottle: Bottle, prefix: URL) throws -> GraphicsLaunchFacts {
        let backend = bottle.graphics.backend
        let component = try graphicsComponent(bottle.graphics)
        try validateGraphicsRuntime(backend, executable: bottle.runtime.executableURL)
        let directory = prefix.deletingLastPathComponent()
        try GraphicsPrefix.validateInstalled(configuration: bottle.graphics, prefix: prefix, bottleDirectory: directory)
        if backend == .dxmt || backend == .d3dmetal {
            let settings = try backend == .dxmt
                ? DXMTInstallation.environment(component: component, showHUD: bottle.graphics.showHUD)
                : D3DMetalInstallation.environment(component: component, showHUD: bottle.graphics.showHUD)
            let folders = backend == .dxmt ? try graphicsDirectories(for: bottle, directory: directory) : nil
            let loader = try GraphicsRuntimeView.prepare(executable: bottle.runtime.executableURL,
                                                         component: component, backend: backend, paths: paths)
            return try .metal(componentSettings: settings, loader: loader,
                              server: bottle.runtime.executableURL.deletingLastPathComponent().appendingPathComponent("wineserver"),
                              folders: folders)
        }
        return .dxvk(component: component, folders: try graphicsDirectories(for: bottle, directory: directory),
                     showHUD: bottle.graphics.showHUD)
    }

    private func graphicsDirectories(for bottle: Bottle, directory: URL) throws -> GraphicsFolders {
        let backend = bottle.graphics.backend
        let cache = directory.appendingPathComponent(backend == .dxvk ? "graphics/cache" : "graphics/dxmt-cache",
                                                     isDirectory: true)
        let logs = paths.logsDirectory.appendingPathComponent("\(bottle.id.uuidString)-\(backend.rawValue)", isDirectory: true)
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

    private func logURL(name: String) -> URL {
        paths.logsDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).log")
    }
}

/// Process-local result of `WineRuntime.prepareIntegrations`, layered in order.
internal struct LaunchIntegrations: Sendable {
    var overrides = DLLOverrides()
    var environment: [String: String] = [:]
    var warnings: [String] = []
}
