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
        let paths = ApplicationPaths(root: root)
        let store = BottleStore(paths: paths)
        let runtime = WineRuntime(paths: paths)
        guard let command = arguments.first else { print(usage); return }
        let values = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h": print(usage)
        case "runtimes":
            for candidate in await runtime.discover() { print("\(candidate.version)\t\(candidate.executableURL.path)") }
        case "install-wine":
            guard values == ["--accept-unsigned"] else {
                throw MagicWineError.setup("Public Wine builds are third-party and unsigned. To verify the download and remove only the managed Wine bundle's quarantine, use install-wine --accept-unsigned. This permits unsigned code to run; a checksum is not a malware assessment. System-wide security settings are unchanged.")
            }
            let installed = try await runtime.installLatest(acceptUnsigned: true)
            print("\(installed.version)\t\(installed.executableURL.path)")
        case "list":
            for bottle in try await store.list() {
                print("\(bottle.id)\t\(bottle.name)\t\(bottle.isInitialized ? "ready" : "setup required")\t\(bottle.runtime.version)\t\(bottle.graphics.backend.rawValue)")
            }
        case "create":
            guard values.count == 2 else { throw argumentError("create <name> <wine-executable>") }
            let descriptor = try await runtime.inspect(executableURL: URL(fileURLWithPath: values[1]))
            var bottle = try await store.create(name: values[0], runtime: descriptor)
            print("Bottle: \(bottle.id)")
            let result = try await runtime.initialize(bottle)
            bottle.isInitialized = true
            try await store.save(bottle)
            print("Ready. Log: \(result.logURL.path)")
        case "initialize", "install", "add", "refresh", "apps", "launch", "stop", "configure", "graphics", "exec":
            guard let identifier = values.first else { throw argumentError("\(command) <bottle-UUID> …") }
            let bottle = try await findBottle(identifier, store: store)
            let rest = Array(values.dropFirst())
            switch command {
            case "initialize":
                let result = try await runtime.initialize(bottle)
                var ready = bottle
                ready.isInitialized = true
                try await store.save(ready)
                print("Ready. Log: \(result.logURL.path)")
            case "install":
                guard rest.count == 1 else { throw argumentError("install <bottle-UUID> <installer.exe|installer.msi>") }
                let result = try await runtime.install(URL(fileURLWithPath: rest[0]), in: bottle)
                let updated = try await store.discoverPrograms(in: bottle)
                print("Installer finished. \(updated.programs.count) saved programs. Log: \(result.logURL.path)")
            case "add":
                guard (1...2).contains(rest.count) else { throw argumentError("add <bottle-UUID> <program.exe|shortcut.lnk> [name]") }
                let updated = try await store.registerProgram(in: bottle, executableURL: URL(fileURLWithPath: rest[0]), name: rest.count == 2 ? rest[1] : nil)
                printPrograms(updated)
            case "refresh": printPrograms(try await store.discoverPrograms(in: bottle))
            case "apps": printPrograms(bottle)
            case "launch":
                guard rest.count == 1, let id = UUID(uuidString: rest[0]), let program = bottle.programs.first(where: { $0.id == id }) else {
                    throw argumentError("launch <bottle-UUID> <program-UUID> (see apps)")
                }
                print("Log: \(try await runtime.launch(program, in: bottle).logURL.path)")
            case "stop": print("Log: \(try await runtime.stop(bottle).logURL.path)")
            case "configure": print("Log: \(try await runtime.configure(bottle).logURL.path)")
            case "graphics":
                if rest.isEmpty {
                    print("\(bottle.graphics.backend.rawValue)\t\(bottle.graphics.componentID ?? "Wine default")\tHUD \(bottle.graphics.showHUD ? "on" : "off")")
                    return
                }
                guard let backend = GraphicsBackend(rawValue: rest[0]) else {
                    throw argumentError("graphics <bottle-UUID> standard|dxvk [--accept-experimental] [--hud|--no-hud]")
                }
                let flags = Set(rest.dropFirst())
                guard flags.count == rest.count - 1,
                      flags.isSubset(of: ["--accept-experimental", "--hud", "--no-hud"]),
                      !(flags.contains("--hud") && flags.contains("--no-hud")),
                      backend == .dxvk || flags.isEmpty else {
                    throw argumentError("graphics <bottle-UUID> standard|dxvk [--accept-experimental] [--hud|--no-hud]")
                }
                let showHUD = flags.contains("--hud") || (!flags.contains("--no-hud") && bottle.graphics.showHUD)
                let updated = try await runtime.configureGraphics(backend, in: bottle, showHUD: showHUD,
                                                                   acceptExperimental: flags.contains("--accept-experimental"))
                print("\(updated.graphics.backend.rawValue)\t\(updated.graphics.componentID ?? "Wine default")\tHUD \(updated.graphics.showHUD ? "on" : "off")")
            case "exec":
                guard !rest.isEmpty else { throw argumentError("exec <bottle-UUID> <wine-arguments…>") }
                let result = try await runtime.run(arguments: rest, in: bottle)
                print(try String(contentsOf: result.logURL, encoding: .utf8))
            default: break
            }
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

    private static func argumentError(_ detail: String) -> MagicWineError { .setup("\(detail)\nRun magicwine --help for usage.") }

    private static let usage = """
    MagicWine — isolated Windows apps on macOS

    magicwine [--root <data-directory>] <command>
      runtimes                                 Find installed Wine
      install-wine --accept-unsigned            Install/reuse Wine and remove its quarantine
      list                                     List bottles and their UUIDs
      create <name> <wine-executable>           Create and initialize a bottle
      initialize <bottle-UUID>                  Retry setup
      install <bottle-UUID> <file.exe|file.msi>  Run an installer
      add <bottle-UUID> <file.exe|file.lnk> [name]
      refresh <bottle-UUID>                    Discover Start Menu shortcuts
      apps <bottle-UUID>                        List saved program UUIDs
      launch <bottle-UUID> <program-UUID>       Run a saved program
      stop <bottle-UUID>                        Stop this bottle only
      configure <bottle-UUID>                   Open Wine configuration
      graphics <bottle-UUID> [standard|dxvk]     Inspect or change graphics backend
        DXVK requires --accept-experimental; optional --hud or --no-hud
      exec <bottle-UUID> <wine-arguments…>       Run Wine with isolated prefix
    """
}
