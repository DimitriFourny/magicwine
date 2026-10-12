import Foundation

public actor WineRuntime {
    public static let distributionNotice = RuntimeInstallation.notice
    private let paths: ApplicationPaths
    private var active: [UUID: [UUID: ProcessOperation]] = [:]
    private var installing = false

    public init(paths: ApplicationPaths) { self.paths = paths }

    public func discover() async -> [RuntimeDescriptor] {
        var candidates: [URL] = []
        let manager = FileManager.default
        if let managed = try? manager.contentsOfDirectory(at: paths.runtimesDirectory,
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for folder in managed {
                candidates.append(folder.appendingPathComponent("Wine Stable.app/Contents/Resources/wine/bin/wine"))
            }
        }
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

    public func installLatest(acceptUnsigned: Bool,
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

    public func launch(_ program: WindowsProgram, in bottle: Bottle) async throws -> OperationResult {
        let executable = try windowsFile(URL(fileURLWithPath: program.executablePath), extensions: ["exe", "lnk"])
        let isShortcut = executable.pathExtension.lowercased() == "lnk"
        let arguments = isShortcut ? ["start", "/unix", executable.path] : [executable.path]
        let result = try await execute(arguments: arguments, bottle: bottle,
                                       directory: executable.deletingLastPathComponent(), timeout: nil)
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
        for operation in active[bottle.id]?.values ?? Dictionary<UUID, ProcessOperation>().values {
            operation.terminate()
        }
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

    public func run(arguments: [String], in bottle: Bottle,
                    timeout: TimeInterval? = nil) async throws -> OperationResult {
        try await execute(arguments: arguments, bottle: bottle, directory: nil, timeout: timeout)
    }

    private func execute(arguments: [String], bottle: Bottle, directory: URL?, timeout: TimeInterval?,
                         server: Bool = false, tracked: Bool = true) async throws -> OperationResult {
        try paths.prepare()
        let prefix = try prefixURL(for: bottle)
        // The descriptor is pinned, never fall back to whichever Wine is in PATH today.
        let wine = bottle.runtime.executableURL.standardizedFileURL
        try validateExecutable(wine)
        let executable = server ? wine.deletingLastPathComponent().appendingPathComponent("wineserver") : wine
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MagicWineError.runtimeUnavailable("The bottle's pinned runtime is missing \(executable.path). Select an intact Wine distribution; this bottle was not migrated.")
        }
        let id = UUID()
        let operation = ProcessOperation(executable: executable, arguments: arguments,
            environment: environment(executable: wine, prefix: prefix), directory: directory ?? prefix,
            logURL: logURL(name: "\(bottle.id.uuidString)-\(server ? "wineserver" : "wine")"), timeout: timeout)
        if tracked { active[bottle.id, default: [:]][id] = operation }
        defer {
            if tracked {
                active[bottle.id]?[id] = nil
                if active[bottle.id]?.isEmpty == true { active[bottle.id] = nil }
            }
        }
        do { return try await operation.run() }
        catch is CancellationError {
            if tracked { await cleanup(bottle) }
            throw CancellationError()
        } catch ProcessOperation.Interrupted.timedOut(let log) {
            if tracked { await cleanup(bottle) }
            throw MagicWineError.setup("Wine operation timed out. Log: \(log.path)")
        }
    }

    private func cleanup(_ bottle: Bottle) async {
        // Cleanup must run even when the initiating task was cancelled.
        let task = Task.detached { [self] in
            _ = try? await self.execute(arguments: ["-k"], bottle: bottle, directory: nil,
                                       timeout: 10, server: true, tracked: false)
        }
        await task.value
    }

    private func environment(executable: URL, prefix: URL?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // Avoid accidental architecture/prefix/loader configuration from a launching shell.
        for key in Array(environment.keys) where key.hasPrefix("WINE") || key.hasPrefix("DYLD_") {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = executable.deletingLastPathComponent().path + ":" +
            (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        if let prefix { environment["WINEPREFIX"] = prefix.path }
        return environment
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

    private func requiresRosetta(_ executable: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: executable)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4096) ?? Data()
        func word(_ offset: Int, little: Bool) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return (0..<4).reduce(UInt32(0)) { value, index in
                value | (UInt32(data[offset + index]) << (8 * (little ? index : 3 - index)))
            }
        }
        guard let magic = word(0, little: false) else { return false }
        if magic == 0xcffaedfe || magic == 0xcefaedfe { return word(4, little: true) == 0x01000007 }
        if magic == 0xfeedfacf || magic == 0xfeedface { return word(4, little: false) == 0x01000007 }
        if magic == 0xcafebabe || magic == 0xcafebabf || magic == 0xbebafeca || magic == 0xbfbafeca {
            let little = magic == 0xbebafeca || magic == 0xbfbafeca
            let stride = (magic == 0xcafebabf || magic == 0xbfbafeca) ? 32 : 20
            let count = Int(word(4, little: little) ?? 0)
            guard count <= (data.count - 8) / stride else { return false }
            var intel = false
            for index in 0..<count {
                let cpu = word(8 + index * stride, little: little)
                if cpu == 0x0100000c { return false }
                if cpu == 0x01000007 { intel = true }
            }
            return intel
        }
        return false
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
