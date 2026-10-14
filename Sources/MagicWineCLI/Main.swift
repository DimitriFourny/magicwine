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
            guard !values.isEmpty else {
                throw MagicWineError.setup("Wine is unsigned and not notarized by Apple. Use install-wine --accept-unsigned to download the Gcenx Wine build with MagicWine’s bundled, pinned source-built DXMT driver bridge. DXMT is also bundled, so enabling it needs no additional download. MagicWine verifies the download checksum and removes only the managed Wine bundle's quarantine. A checksum is not a malware assessment; system-wide security settings are unchanged.")
            }
            guard values == ["--accept-unsigned"] else {
                throw argumentError("install-wine --accept-unsigned")
            }
            let installed = try await runtime.installRuntime(acceptUnsigned: true)
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
        case "initialize", "install", "add", "refresh", "apps", "launch", "stop", "configure", "graphics", "retina", "exec":
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
                guard (1...2).contains(rest.count) else { throw argumentError("add <bottle-UUID> <program.exe|shortcut.lnk|shortcut.url> [name]") }
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
                let updated = try await runtime.configureGraphics(backend, in: bottle, showHUD: showHUD,
                                                                   acceptExperimental: flags.contains("--accept-experimental"),
                                                                   componentSource: componentSource)
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

    private static let graphicsUsage = "graphics <bottle-UUID> standard|dxvk|dxmt|d3dmetal [--accept-experimental] [--hud|--no-hud] [--import <D3DMetal-library-folder>]"

    private static let usage = """
    MagicWine — isolated Windows apps on macOS

    magicwine [--root <data-directory>] <command>
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
      stop <bottle-UUID>                        Stop this bottle only
      configure <bottle-UUID>                   Open Wine configuration
      graphics <bottle-UUID> [standard|dxvk|dxmt|d3dmetal]
        Third-party backends require --accept-experimental; optional --hud or --no-hud
        D3DMetal finds local Wine/CrossOver libraries; --import <library-folder> overrides discovery
      retina <bottle-UUID> [on|off]              Read or change Retina / HiDPI (default on)
        On sets 200% scaling (192 DPI); off sets 100% (96 DPI)
        Bottle-wide changes affect games too and stop this bottle’s Windows processes
      exec <bottle-UUID> <wine-arguments…>       Run Wine with isolated prefix
    """
}
