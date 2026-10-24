import Foundation

/// Facts `WineRuntime` derives from a pinned executable's canonical location.
internal struct LaunchRuntimeFacts: Hashable, Sendable {
    /// The exact current managed runtime: MagicWine owns its MSync/ESync/FSync switches.
    var managedMSync: Bool
    /// Any managed Metal runtime revision: needs Mono's fallback TLS.
    var managedMetal: Bool
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
/// backend < bottle settings < program settings. A higher layer wins per variable and
/// per DLL; `WINEDLLOVERRIDES` is only ever produced from the merged `DLLOverrides`.
internal enum LaunchPlanner {
    struct Layer {
        var set: [String: String] = [:]
        var unset: Set<String> = []
        var overrides = DLLOverrides()
    }

    static func plan(_ request: LaunchRequest) -> LaunchPlan {
        var environment = scrubbed(request.inherited, managedMSync: request.runtime.managedMSync)
        var executable = request.executable
        var layers = [base(request, scrubbed: environment)]
        if let integrations = request.integrations {
            layers.append(Layer(set: integrations.environment, overrides: integrations.overrides))
        }
        if let graphics = request.graphics {
            let (layer, loader) = graphicsLayer(graphics)
            layers.append(layer)
            if let loader { executable = loader }
        }
        var overrides = DLLOverrides()
        for layer in layers {
            for key in layer.unset { environment.removeValue(forKey: key) }
            environment.merge(layer.set) { _, higher in higher }
            overrides = overrides.layered(with: layer.overrides)
        }
        environment["WINEDLLOVERRIDES"] = overrides.serialized
        return LaunchPlan(executable: executable, arguments: request.arguments, environment: environment,
                          directory: request.directory, warnings: request.integrations?.warnings ?? [])
    }

    /// Inherited loader/prefix/graphics settings never leak in. Custom Wine keeps its
    /// own synchronization switches; only the managed backend owns them.
    static func scrubbed(_ inherited: [String: String], managedMSync: Bool) -> [String: String] {
        inherited.filter { key, _ in
            !((key.hasPrefix("WINE") &&
               (managedMSync || (key != "WINEMSYNC" && key != "WINEESYNC" && key != "WINEFSYNC"))) ||
              key.hasPrefix("DYLD_") || key.hasPrefix("DXVK_") || key.hasPrefix("DXMT_") ||
              key.hasPrefix("D3DM_") || key.hasPrefix("MTL_") || key.hasPrefix("MAGICWINE_GAMEPAD_") ||
              key == "CX_APPLEGPTK_LIBD3DSHARED_PATH")
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
        case .dxvk(let component, let folders, let showHUD):
            layer.overrides = try! DLLOverrides(parsing: "d3d9,d3d10core,d3d11=n;dxgi=b")
            // Builtin DXGI enumerates a WineD3D adapter before handing devices to DXVK.
            // Avoid its OpenGL/WoW64 initialization path even when the HUD is disabled.
            layer.set["WINE_D3D_CONFIG"] = "renderer=vulkan"
            layer.set["DXVK_CONFIG_FILE"] = component.appendingPathComponent("dxvk.conf").path
            layer.set["DXVK_STATE_CACHE_PATH"] = folders.cache.path
            layer.set["DXVK_LOG_PATH"] = folders.logs.path
            if showHUD { layer.set["DXVK_HUD"] = "version,api,devinfo,fps,frametimes" }
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
