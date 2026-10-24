import Foundation
import MagicWineCore
import Darwin

@main
struct MagicWineCLI {
    static func main() async {
        do {
            try await execute(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func execute(_ input: [String]) async throws {
        var arguments = input
        var root: URL?
        if arguments.first == "--root" {
            guard arguments.count >= 3 else { throw MagicWineError.setup("--root requires a directory and command.") }
            root = URL(fileURLWithPath: arguments[1], isDirectory: true)
            arguments.removeFirst(2)
        }
        if arguments.first == "--version" || arguments.first == "version" { print(versionDescription); return }
        let paths = ApplicationPaths(root: root)
        let store = BottleStore(paths: paths)
        let runtime = WineRuntime(paths: paths, store: store)
        guard let command = arguments.first else { print(usage); return }
        let values = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h": print(usage)
        case "runtimes":
            for candidate in await runtime.discover() { print("\(candidate.version)\t\(candidate.executableURL.path)") }
        case "install-wine":
            guard !values.isEmpty else {
                throw MagicWineError.setup("Wine is unsigned and not notarized by Apple. Use install-wine --accept-unsigned to download the Gcenx Wine build with MagicWine’s bundled, pinned source-built DXMT driver bridge. DXMT is also bundled, so enabling it needs no additional download. MagicWine verifies the download checksum and removes only the managed Wine bundle's quarantine. A checksum is not a malware assessment; system-wide security settings are unchanged.")
            }
            guard values == ["--accept-unsigned"] else {
                throw argumentError("install-wine --accept-unsigned")
            }
            let installed = try await runtime.installRuntime(acceptUnsigned: true)
            print("\(installed.version)\t\(installed.executableURL.path)")
        case "runtime":
            guard values.count == 2, values[0] == "upgrade" else {
                throw argumentError("runtime upgrade <bottle-UUID>")
            }
            let bottle = try await findBottle(values[1], store: store)
            let updated = try await runtime.upgradeRuntime(in: bottle)
            print("\(updated.runtime.version)\t\(updated.runtime.executableURL.path)")
        case "list":
            for bottle in try await store.list() {
                print("\(bottle.id)\t\(bottle.name)\t\(bottle.isInitialized ? "ready" : "setup required")\t\(bottle.runtime.version)\t\(bottle.graphics.backend.rawValue)\t\(synchronizationDescription(bottle, runtime: runtime))")
            }
        case "create":
            guard values.count == 2 else { throw argumentError("create <name> <wine-executable>") }
            let descriptor = try await runtime.inspect(executableURL: URL(fileURLWithPath: values[1]))
            let bottle = try await store.create(name: values[0], runtime: descriptor)
            print("Bottle: \(bottle.id)")
            print("Ready. Log: \(try await runtime.initialize(bottle).result.logURL.path)")
        case "initialize", "install", "add", "refresh", "apps", "launch", "stop", "configure", "graphics", "retina", "synchronization", "exec":
            guard let identifier = values.first else { throw argumentError("\(command) <bottle-UUID> …") }
            let bottle = try await findBottle(identifier, store: store)
            let rest = Array(values.dropFirst())
            switch command {
            case "initialize":
                print("Ready. Log: \(try await runtime.initialize(bottle).result.logURL.path)")
            case "install":
                guard rest.count == 1 else { throw argumentError("install <bottle-UUID> <installer.exe|installer.msi>") }
                let result = try await runtime.install(URL(fileURLWithPath: rest[0]), in: bottle)
                let updated = try await store.discoverPrograms(in: bottle)
                print("Installer finished. \(updated.programs.count) saved programs. Log: \(result.logURL.path)")
            case "add":
                guard (1...2).contains(rest.count) else { throw argumentError("add <bottle-UUID> <program.exe|shortcut.lnk|shortcut.url> [name]") }
                let updated = try await store.registerProgram(in: bottle, executableURL: URL(fileURLWithPath: rest[0]), name: rest.count == 2 ? rest[1] : nil)
                printPrograms(updated)
            case "refresh": printPrograms(try await store.discoverPrograms(in: bottle))
            case "apps": printPrograms(bottle)
            case "launch":
                let diagnostics = rest.count == 2 && rest[1] == "--diagnostics"
                guard rest.count == 1 || diagnostics, let id = UUID(uuidString: rest[0]),
                      let program = bottle.programs.first(where: { $0.id == id }) else {
                    throw argumentError("launch <bottle-UUID> <program-UUID> [--diagnostics] (see apps)")
                }
                let result = try await runtime.launch(program, in: bottle, diagnostics: diagnostics, onStart: printWarnings)
                print("\(diagnostics ? "Diagnostic log (WINEDEBUG=\(WineRuntime.diagnosticWineDebug))" : "Log"): \(result.logURL.path)")
                print("Exit code: \(result.exitCode)")
                if result.exitCode != 0 {
                    if let summary = ProcessLogSummary.summary(at: result.logURL) {
                        FileHandle.standardError.write(Data("\(summary)\n".utf8))
                    }
                    exit(result.exitCode)
                }
            case "stop": print("Log: \(try await runtime.stop(bottle).logURL.path)")
            case "configure": print("Log: \(try await runtime.configure(bottle).logURL.path)")
            case "synchronization":
                guard rest.isEmpty || (rest.count == 1 && ["msync", "server"].contains(rest[0])) else {
                    throw argumentError("synchronization <bottle-UUID> [msync|server]")
                }
                let updated: Bottle
                if let setting = rest.first {
                    updated = try await runtime.configureSynchronization(msyncEnabled: setting == "msync", in: bottle)
                } else {
                    updated = bottle
                }
                print(synchronizationDescription(updated, runtime: runtime))
            case "retina":
                guard rest.isEmpty || (rest.count == 1 && ["on", "off"].contains(rest[0])) else {
                    throw argumentError("retina <bottle-UUID> [on|off]")
                }
                let updated: Bottle
                if let setting = rest.first {
                    updated = try await runtime.configureDisplay(retinaEnabled: setting == "on", in: bottle)
                } else {
                    updated = bottle
                }
                print("Retina \(updated.display.retinaEnabled ? "on" : "off")\t\(updated.display.dpi) DPI")
            case "graphics":
                if rest.isEmpty {
                    print("\(bottle.graphics.backend.rawValue)\t\(bottle.graphics.componentID ?? "Wine default")\tHUD \(bottle.graphics.showHUD ? "on" : "off")")
                    return
                }
                guard let backend = GraphicsBackend(rawValue: rest[0]) else {
                    throw argumentError(graphicsUsage)
                }
                var flags = Set<String>()
                var componentSource: URL?
                var index = 1
                while index < rest.count {
                    let flag = rest[index]
                    guard flags.insert(flag).inserted else { throw argumentError(graphicsUsage) }
                    if flag == "--import" {
                        guard backend == .d3dmetal, index + 1 < rest.count,
                              !rest[index + 1].hasPrefix("--") else { throw argumentError(graphicsUsage) }
                        componentSource = URL(fileURLWithPath: rest[index + 1], isDirectory: true)
                        index += 2
                    } else {
                        guard ["--accept-experimental", "--hud", "--no-hud"].contains(flag) else {
                            throw argumentError(graphicsUsage)
                        }
                        index += 1
                    }
                }
                guard !(flags.contains("--hud") && flags.contains("--no-hud")),
                      backend != .standard || flags.isEmpty else { throw argumentError(graphicsUsage) }
                let showHUD = flags.contains("--hud") || (!flags.contains("--no-hud") && bottle.graphics.showHUD)
                let updated: Bottle
                if backend == bottle.graphics.backend, backend != .standard, componentSource == nil,
                   flags.contains("--hud") || flags.contains("--no-hud") {
                    // HUD only: metadata for later launches; running programs are not stopped.
                    updated = try await runtime.setGraphicsHUD(showHUD, in: bottle)
                } else {
                    updated = try await runtime.configureGraphics(backend, in: bottle, showHUD: showHUD,
                                                                  acceptExperimental: flags.contains("--accept-experimental"),
                                                                  componentSource: componentSource)
                }
                print("\(updated.graphics.backend.rawValue)\t\(updated.graphics.componentID ?? "Wine default")\tHUD \(updated.graphics.showHUD ? "on" : "off")")
            case "exec":
                guard !rest.isEmpty else { throw argumentError("exec <bottle-UUID> <wine-arguments…>") }
                do {
                    let result = try await runtime.run(arguments: rest, in: bottle, onStart: printWarnings)
                    print(try String(contentsOf: result.logURL, encoding: .utf8))
                } catch MagicWineError.processFailed(let code, let log) {
                    // Report Wine's own status instead of the generic CLI failure status.
                    print(try String(contentsOf: log, encoding: .utf8))
                    FileHandle.standardError.write(Data("error: Wine exited with code \(code)\n".utf8))
                    exit(code)
                }
            default: break
            }
        case "program":
            guard values.count >= 2, let id = UUID(uuidString: values[1]) else { throw argumentError(programUsage) }
            let bottle = try await findBottle(values[0], store: store)
            guard let original = bottle.programs.first(where: { $0.id == id }) else {
                throw argumentError("Unknown program UUID (see apps).\n" + programUsage)
            }
            var edited = original
            var index = 2
            func next() throws -> String {
                guard index + 1 < values.count else { throw argumentError(programUsage) }
                index += 1
                return values[index]
            }
            func pair(_ text: String) throws -> (String, String) {
                guard let separator = text.firstIndex(of: "="), separator != text.startIndex else { throw argumentError(programUsage) }
                return (String(text[..<separator]), String(text[text.index(after: separator)...]))
            }
            while index < values.count {
                switch values[index] {
                case "--name": edited.name = try next()
                case "--args": edited.arguments = try WindowsProgram.parseArguments(next())
                case "--workdir": edited.workingDirectory = URL(fileURLWithPath: try next(), isDirectory: true).standardizedFileURL.path
                case "--clear-workdir": edited.workingDirectory = nil
                case "--env":
                    let (key, value) = try pair(next())
                    edited.environment[key] = value
                case "--unset-env": edited.environment[try next()] = nil
                case "--dll":
                    let (name, mode) = try pair(next())
                    try edited.dllOverrides.set(DLLOverrides.Mode(parsing: mode), for: name)
                case "--unset-dll": edited.dllOverrides.remove(try next())
                case "--avx":
                    switch try next() {
                    case "inherit": edited.advertiseAVX = nil
                    case "on": edited.advertiseAVX = true
                    case "off": edited.advertiseAVX = false
                    default: throw argumentError(programUsage)
                    }
                default: throw argumentError(programUsage)
                }
                index += 1
            }
            var program = original
            if edited != original {
                // Metadata only: running programs keep going; the next launch uses it.
                let updated = try await store.updateProgram(edited, from: original, in: bottle)
                program = updated.programs.first { $0.id == id } ?? edited
            }
            printProgramOptions(program)
        case "compat":
            guard let identifier = values.first else { throw argumentError(compatUsage) }
            let bottle = try await findBottle(identifier, store: store)
            var options = bottle.compatibility
            var index = 1
            while index < values.count {
                guard index + 1 < values.count else { throw argumentError(compatUsage) }
                let value = values[index + 1]
                switch (values[index], value) {
                case ("--avx", "on"), ("--avx", "off"): options.advertiseAVX = value == "on"
                case ("--winedebug", "quiet"): options.wineDebug = .quiet
                case ("--winedebug", "default"): options.wineDebug = .wineDefault
                case ("--dxvk-hud", _):
                    guard let preset = CompatibilityOptions.DXVKHUD(rawValue: value) else { throw argumentError(compatUsage) }
                    options.dxvkHUD = preset
                default: throw argumentError(compatUsage)
                }
                index += 2
            }
            // Launch switches only: running programs keep going; later launches use them.
            let updated = options == bottle.compatibility ? bottle : try await store.setCompatibility(options, in: bottle)
            let avx: String
            switch runtime.rosettaAVXAvailability(updated.runtime) {
            case .available: avx = "available"
            case .unavailable(let reason): avx = "not applied: \(reason)"
            }
            print("avx\t\(updated.compatibility.advertiseAVX ? "on" : "off")\t\(avx)")
            print("winedebug\t\(updated.compatibility.wineDebug.rawValue)\t\(updated.compatibility.wineDebug == .quiet ? "WINEDEBUG=\(WineRuntime.quietWineDebug)" : "Wine's default")")
            print("dxvk-hud\t\(updated.compatibility.dxvkHUD.rawValue)\tDXVK_HUD=\(updated.compatibility.dxvkHUD.value) when the HUD is on")
        case "cleanup":
            let flags = Set(values)
            guard flags.count == values.count, flags.isSubset(of: ["--apply", "--include-current"]) else {
                throw argumentError("cleanup [--apply] [--include-current]")
            }
            let plan = try await StorageCleanup.plan(paths: paths, includeCurrent: flags.contains("--include-current"))
            for category in StorageCleanupItem.Category.allCases {
                let items = plan.items.filter { $0.category == category }
                guard !items.isEmpty else { continue }
                print(category.title)
                for item in items { print("  \(byteCount(item.size))\t\(item.url.path)\n    \(item.reason)") }
            }
            for item in plan.keptCurrent {
                print("Kept (current; add --include-current to remove): \(byteCount(item.size))\t\(item.url.path)")
            }
            guard flags.contains("--apply") else {
                print("Total: \(plan.items.count) items, \(byteCount(plan.totalSize)). Dry run; run cleanup --apply to remove them.")
                return
            }
            let result = try await StorageCleanup.apply(plan.items, paths: paths)
            for item in result.removed { print("Removed\t\(item.url.path)") }
            for item in result.skipped { print("Skipped (no longer removable)\t\(item.url.path)") }
            print("Removed \(result.removed.count) items, \(byteCount(result.reclaimedSize)).")
        default: throw argumentError("Unknown command: \(command)")
        }
    }

    private static func findBottle(_ identifier: String, store: BottleStore) async throws -> Bottle {
        guard let id = UUID(uuidString: identifier), let bottle = try await store.list().first(where: { $0.id == id }) else {
            throw MagicWineError.invalidBottle
        }
        return bottle
    }

    private static func printPrograms(_ bottle: Bottle) {
        for program in bottle.programs { print("\(program.id)\t\(program.name)\t\(program.executablePath)") }
    }

    private static func printProgramOptions(_ program: WindowsProgram) {
        print("\(program.id)\t\(program.name)\t\(program.executablePath)")
        if program.supportsArgumentsAndDirectory {
            print("arguments\t\(WindowsProgram.formatArguments(program.arguments))")
            print("workdir\t\(program.workingDirectory ?? "(EXE folder)")")
        } else {
            print("arguments\t(not used: Wine starts LNK/URL shortcuts with their own arguments and folder)")
        }
        for key in program.environment.keys.sorted() { print("env\t\(key)=\(program.environment[key] ?? "")") }
        if !program.dllOverrides.isEmpty { print("dll\t\(program.dllOverrides.serialized)") }
        if let avx = program.advertiseAVX { print("avx\t\(avx ? "on" : "off")") }
    }

    /// Called as soon as Wine starts; a long-running program can exit much later.
    private static let printWarnings: @Sendable (LaunchStart) -> Void = { start in
        for warning in start.warnings {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }
    }

    private static func synchronizationDescription(_ bottle: Bottle, runtime: WineRuntime) -> String {
        guard runtime.supportsMSync(bottle.runtime) else {
            return "MSync unavailable (preference \(bottle.msyncEnabled ? "on" : "off"); pinned Wine unchanged)"
        }
        return bottle.msyncEnabled ? "msync" : "server"
    }

    private static func argumentError(_ detail: String) -> MagicWineError { .setup("\(detail)\nRun magicwine --help for usage.") }

    private static func byteCount(_ size: Int64) -> String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    private static let graphicsUsage = "graphics <bottle-UUID> standard|dxvk|dxmt|d3dmetal [--accept-experimental] [--hud|--no-hud] [--import <D3DMetal-library-folder>]"

    private static let programUsage = "program <bottle-UUID> <program-UUID> [--name <name>] [--args \"<arguments>\"] [--workdir <folder>|--clear-workdir] [--env KEY=VALUE]… [--unset-env KEY]… [--dll <name>=n|b|n,b|b,n|disabled]… [--unset-dll <name>]… [--avx inherit|on|off]"

    private static let compatUsage = "compat <bottle-UUID> [--avx on|off] [--winedebug quiet|default] [--dxvk-hud fps|detailed]"

    /// The enclosing app's Info.plist when packaged (`Contents/MacOS/magicwine-cli`); plain `swift build` binaries have none.
    private static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String else { return "magicwine development build" }
        let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        let revision = (info?["MagicWineGitRevision"] as? String).map { " \($0)" } ?? ""
        return "magicwine \(version)\(build)\(revision)"
    }

    private static let usage = """
    MagicWine — isolated Windows apps on macOS

    magicwine [--root <data-directory>] <command>
      --version | version                       Print the MagicWine version
      runtimes                                 Find installed Wine
      install-wine --accept-unsigned
        Install/reuse Wine from Gcenx with the source-built DXMT/D3DMetal driver bridge
        DXMT is included; enabling it requires no additional download
      list                                     List bottles and their UUIDs
      create <name> <wine-executable>           Create and initialize a bottle
      initialize <bottle-UUID>                  Retry setup
      install <bottle-UUID> <file.exe|file.msi>  Run an installer
      add <bottle-UUID> <file.exe|file.lnk|file.url> [name]
      refresh <bottle-UUID>                    Discover Start Menu and Desktop LNK/URL shortcuts
      apps <bottle-UUID>                        List saved program UUIDs
      launch <bottle-UUID> <program-UUID>       Run a saved program
        Prints its exit code and exits with it (low 8 bits of the Windows code)
        --diagnostics: one-off launch with WINEDEBUG=+loaddll,+seh,+process (not saved); prints its log
      stop <bottle-UUID>                        Stop this bottle only
      configure <bottle-UUID>                   Open Wine configuration
      graphics <bottle-UUID> [standard|dxvk|dxmt|d3dmetal]
        Third-party backends require --accept-experimental; optional --hud or --no-hud
        The current backend with --hud/--no-hud only saves the HUD for later launches:
        no --accept-experimental needed, running programs are not stopped
        D3DMetal finds local Wine/CrossOver libraries; --import <library-folder> overrides discovery
      retina <bottle-UUID> [on|off]              Read or change Retina / HiDPI (default on)
        On sets 200% scaling (192 DPI); off sets 100% (96 DPI)
        Bottle-wide changes affect games too and stop this bottle’s Windows processes
      synchronization <bottle-UUID> [msync|server]
        Read or change synchronization (default MSync); requires idle updated managed Wine
      runtime upgrade <bottle-UUID>             Explicitly adopt installed updated Wine for an old managed bottle
        Run install-wine --accept-unsigned first; does not download Wine or change custom runtime bottles
      exec <bottle-UUID> <wine-arguments…>       Run Wine with isolated prefix
        Prints the log; exits with Wine's exit code
      program <bottle-UUID> <program-UUID> [options]
        Show or edit a saved program's name and launch options for its next launch
        --name N, --args "…" (quoted like a shell; "" clears), --workdir PATH | --clear-workdir,
        --env K=V / --unset-env K, --dll name=n|b|n,b|b,n|disabled / --unset-dll name (repeatable)
        Arguments and working directory apply to EXE programs only; running programs are not stopped
        --avx inherit|on|off overrides the bottle's Rosetta AVX setting for this program
      compat <bottle-UUID> [--avx on|off] [--winedebug quiet|default] [--dxvk-hud fps|detailed]
        Show or change launch switches: Rosetta AVX advertising (x86_64 Wine, macOS 15+),
        Wine debug output (quiet = WINEDEBUG=fixme-all), and the DXVK HUD preset
        Saved for later launches; running programs are not stopped
      cleanup [--apply] [--include-current]
        List unused components, managed Wine runtimes, private graphics views, installer leftovers
        and lock files of deleted bottles with sizes (dry run); --apply removes them while all bottles are idle
        Current managed Wine and bundled components are kept unless --include-current
    """
}
