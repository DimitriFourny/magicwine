import Foundation

/// Facts `WineRuntime` derives from a pinned executable's canonical location.
internal struct LaunchRuntimeFacts: Hashable, Sendable {
    /// The exact current managed runtime: MagicWine owns its MSync/ESync/FSync switches.
    var managedMSync: Bool
    /// Any managed Metal runtime revision: needs Mono's fallback TLS.
    var managedMetal: Bool
    /// x86_64 Wine under Rosetta 2 on macOS 15+: `ROSETTA_ADVERTISE_AVX` is honored.
    var rosettaAVX = false
}

/// Bottle-owned graphics folders, created and checked by `WineRuntime`.
internal struct GraphicsFolders: Hashable, Sendable {
    var cache: URL
    var logs: URL
}

/// A non-Standard backend's validated launch inputs. `WineRuntime` verifies the
/// component and prefix footprint and prepares any private runtime view first.
internal enum GraphicsLaunchFacts: Hashable, Sendable {
    case dxvk(component: URL, folders: GraphicsFolders, showHUD: Bool)
    /// `environment` and `overrides` are a Metal component's own settings
    /// (`DXMTInstallation`/`D3DMetalInstallation.environment`); `loader` is the private
    /// runtime view's executable; `server` stays the bottle's pinned wineserver.
    case metal(environment: [String: String], overrides: DLLOverrides, loader: URL, server: URL,
               folders: GraphicsFolders?)

    /// Splits a Metal component's settings into variables and typed DLL overrides.
    static func metal(componentSettings: [String: String], loader: URL, server: URL,
                      folders: GraphicsFolders?) throws -> GraphicsLaunchFacts {
        var environment = componentSettings
        let overrides = try DLLOverrides(parsing: environment.removeValue(forKey: "WINEDLLOVERRIDES") ?? "")
        return .metal(environment: environment, overrides: overrides, loader: loader, server: server, folders: folders)
    }
}

/// Everything one Wine process needs, gathered after all side effects are done.
internal struct LaunchRequest: Sendable {
    var inherited: [String: String]
    var runtime: LaunchRuntimeFacts
    /// The pinned `wine` (or `wineserver`); a Metal backend substitutes its loader.
    var executable: URL
    var arguments: [String]
    var directory: URL?
    var prefix: URL?
    var msyncEnabled = true
    var integrations: LaunchIntegrations?
    var graphics: GraphicsLaunchFacts?
    /// Bottle switches for a Windows process (never for server operations).
    var compatibility: CompatibilityOptions?
    /// A saved program's options (validated by `WineRuntime`), applied last.
    var program: WindowsProgram?
    /// One-off diagnostic launch: its `WINEDEBUG` wins over every saved setting.
    var diagnostics = false
}

internal struct LaunchPlan: Equatable, Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    var directory: URL?
    var warnings: [String]
}

/// Pure launch policy: turns explicit facts into the exact process to start. Layers,
/// lowest to highest: managed base defaults < compatibility integrations < graphics
/// backend < bottle settings < program settings < one-off diagnostics. A higher layer
/// wins per variable and per DLL; `WINEDLLOVERRIDES` is only ever produced from the
/// merged `DLLOverrides`.
internal enum LaunchPlanner {
    struct Layer {
        var set: [String: String] = [:]
        var unset: Set<String> = []
        var overrides = DLLOverrides()
    }

    /// Quiet default: hides Wine's fixme noise but keeps the `err:` lines that
    /// `ProcessLogSummary` reports.
    static let quietWineDebug = "fixme-all"
    /// Diagnostic launches add DLL load decisions, exceptions, and process creation to
    /// Wine's default error and fixme output; see docs/debugging.md.
    static let diagnosticWineDebug = "+loaddll,+seh,+process"

    static func plan(_ request: LaunchRequest) -> LaunchPlan {
        var environment = scrubbed(request.inherited, managedMSync: request.runtime.managedMSync)
        var executable = request.executable
        var arguments = request.arguments
        var directory = request.directory
        var warnings = request.integrations?.warnings ?? []
        var layers = [base(request, scrubbed: environment)]
        if let integrations = request.integrations {
            layers.append(Layer(set: integrations.environment, overrides: integrations.overrides))
        }
        if let graphics = request.graphics {
            let (layer, loader) = graphicsLayer(graphics)
            layers.append(layer)
            if let loader { executable = loader }
        }
        if let options = request.compatibility {
            var layer = Layer()
            if options.wineDebug == .quiet { layer.set["WINEDEBUG"] = quietWineDebug }
            if options.advertiseAVX, request.runtime.rosettaAVX { layer.set["ROSETTA_ADVERTISE_AVX"] = "1" }
            if case .dxvk(_, _, true)? = request.graphics { layer.set["DXVK_HUD"] = options.dxvkHUD.value }
            layers.append(layer)
        }
        if let program = request.program {
            var layer = Layer(overrides: program.dllOverrides)
            if let avx = program.advertiseAVX {
                if avx, request.runtime.rosettaAVX { layer.set["ROSETTA_ADVERTISE_AVX"] = "1" }
                else { layer.unset.insert("ROSETTA_ADVERTISE_AVX") }
            }
            layer.set.merge(program.environment) { _, explicit in explicit }
            layers.append(layer)
            if program.supportsArgumentsAndDirectory {
                arguments += program.arguments
                if let folder = program.workingDirectory { directory = URL(fileURLWithPath: folder, isDirectory: true) }
            }
        }
        if request.program?.advertiseAVX ?? request.compatibility?.advertiseAVX ?? false, !request.runtime.rosettaAVX {
            warnings.append("Rosetta AVX advertising is on but was not applied: it needs x86_64 Wine running under Rosetta 2 on macOS 15 or later.")
        }
        if request.diagnostics { layers.append(Layer(set: ["WINEDEBUG": diagnosticWineDebug])) }
        var overrides = DLLOverrides()
        for layer in layers {
            for key in layer.unset { environment.removeValue(forKey: key) }
            environment.merge(layer.set) { _, higher in higher }
            overrides = overrides.layered(with: layer.overrides)
        }
        environment["WINEDLLOVERRIDES"] = overrides.serialized
        return LaunchPlan(executable: executable, arguments: arguments, environment: environment,
                          directory: directory, warnings: warnings)
    }

    /// Inherited loader/prefix/graphics settings never leak in. Custom Wine keeps its
    /// own synchronization switches; only the managed backend owns them. Rosetta AVX
    /// advertising belongs to the bottle and program settings.
    static func scrubbed(_ inherited: [String: String], managedMSync: Bool) -> [String: String] {
        inherited.filter { key, _ in
            !((key.hasPrefix("WINE") &&
               (managedMSync || (key != "WINEMSYNC" && key != "WINEESYNC" && key != "WINEFSYNC"))) ||
              key.hasPrefix("DYLD_") || key.hasPrefix("DXVK_") || key.hasPrefix("DXMT_") ||
              key.hasPrefix("D3DM_") || key.hasPrefix("MTL_") || key.hasPrefix("MAGICWINE_GAMEPAD_") ||
              key == "CX_APPLEGPTK_LIBD3DSHARED_PATH" || key == "ROSETTA_ADVERTISE_AVX")
        }
    }

    private static func base(_ request: LaunchRequest, scrubbed: [String: String]) -> Layer {
        var layer = Layer()
        layer.set["PATH"] = request.executable.deletingLastPathComponent().path + ":" +
            (scrubbed["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        if let prefix = request.prefix { layer.set["WINEPREFIX"] = prefix.path }
        // Prefer application-local browser interop assemblies over Wine's namesake DLL.
        try! layer.overrides.set(.nativeThenBuiltin, for: "shdocvw")
        if request.runtime.managedMSync {
            layer.set["WINEMSYNC"] = request.msyncEnabled ? "1" : "0"
            layer.set["WINEESYNC"] = "0"
            layer.set["WINEFSYNC"] = "0"
        }
        // Managed Metal Wine keeps native pthread GS active. Mono's inline
        // GS-relative dynamic TLS reads bypass the real Windows TEB; its API
        // TLS mode works across Standard, DXVK, DXMT and D3DMetal launches.
        // Older bottles retain their pinned Metal runtime when a newer managed
        // build is installed; they still need the same Mono TLS correction.
        if request.prefix != nil, request.runtime.managedMetal {
            let option = "use-fallback-tls"
            let existing = scrubbed["MONO_DEBUG"] ?? ""
            if !existing.split(separator: ",").contains(Substring(option)) {
                layer.set["MONO_DEBUG"] = existing.isEmpty ? option : existing + "," + option
            }
        }
        return layer
    }

    private static func graphicsLayer(_ graphics: GraphicsLaunchFacts) -> (Layer, loader: URL?) {
        var layer = Layer()
        switch graphics {
        case .dxvk(let component, let folders, _):
            // DXVK_HUD comes from the bottle layer's HUD preset when the HUD is on.
            layer.overrides = try! DLLOverrides(parsing: "d3d9,d3d10core,d3d11=n;dxgi=b")
            // Builtin DXGI enumerates a WineD3D adapter before handing devices to DXVK.
            // Avoid its OpenGL/WoW64 initialization path even when the HUD is disabled.
            layer.set["WINE_D3D_CONFIG"] = "renderer=vulkan"
            layer.set["DXVK_CONFIG_FILE"] = component.appendingPathComponent("dxvk.conf").path
            layer.set["DXVK_STATE_CACHE_PATH"] = folders.cache.path
            layer.set["DXVK_LOG_PATH"] = folders.logs.path
            return (layer, nil)
        case .metal(let environment, let overrides, let loader, let server, let folders):
            layer.set = environment
            layer.overrides = overrides
            if let folders {
                layer.set["DXMT_LOG_PATH"] = folders.logs.path
                layer.set["DXMT_SHADER_CACHE_PATH"] = folders.cache.path
            }
            layer.set["WINELOADER"] = loader.path
            layer.set["WINESERVER"] = server.path
            return (layer, loader)
        }
    }
}
