import Foundation
import Testing
@testable import MagicWineCore

struct LaunchPlannerTests {
    private static let root = URL(fileURLWithPath: "/Library/MagicWine")
    private static let wine = root.appendingPathComponent("Runtimes/managed/bin/wine")
    private static let prefix = root.appendingPathComponent("Bottles/B/prefix")
    private static let program = prefix.appendingPathComponent("drive_c/Game/game.exe")
    private static let xinput = "xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0"
    private static let inherited = [
        "PATH": "/usr/bin:/bin", "HOME": "/Users/player", "LANG": "en_US.UTF-8",
        "WINEPREFIX": "/elsewhere", "WINEDEBUG": "+all", "WINEDLLOVERRIDES": "d3d11=n", "WINELOADER": "/x",
        "WINEMSYNC": "1", "WINEESYNC": "1", "WINEFSYNC": "1", "DYLD_LIBRARY_PATH": "/x", "DXVK_HUD": "full",
        "DXMT_LOG_LEVEL": "debug", "D3DM_DEBUG": "1", "MTL_HUD_ENABLED": "1", "MAGICWINE_GAMEPAD_STATE": "stale",
        "CX_APPLEGPTK_LIBD3DSHARED_PATH": "/x", "MONO_DEBUG": "existing",
    ]

    private static func integrations() throws -> LaunchIntegrations {
        var integrations = LaunchIntegrations()
        integrations.overrides = try DLLOverrides(parsing: "wow64cpu=n;" + GamepadBridge.overrides)
        integrations.environment = ["MAGICWINE_GAMEPAD_STATE": "Z:\\state"]
        integrations.warnings = ["skipped"]
        return integrations
    }

    private static func request(graphics: GraphicsLaunchFacts? = nil, msync: Bool = true,
                                managed: Bool = true) throws -> LaunchRequest {
        LaunchRequest(inherited: inherited, runtime: LaunchRuntimeFacts(managedMSync: managed, managedMetal: managed),
                      executable: wine, arguments: [program.path], directory: program.deletingLastPathComponent(),
                      prefix: prefix, msyncEnabled: msync, integrations: try integrations(), graphics: graphics,
                      compatibility: CompatibilityOptions())
    }

    /// The managed base, integrations, default bottle switches, and nothing inherited
    /// that MagicWine owns.
    private static let standard = [
        "PATH": wine.deletingLastPathComponent().path + ":/usr/bin:/bin", "HOME": "/Users/player", "LANG": "en_US.UTF-8",
        "WINEPREFIX": prefix.path, "WINEMSYNC": "1", "WINEESYNC": "0", "WINEFSYNC": "0",
        "MONO_DEBUG": "existing,use-fallback-tls", "MAGICWINE_GAMEPAD_STATE": "Z:\\state",
        "WINEDLLOVERRIDES": "shdocvw=n,b;wow64cpu=n;\(xinput)=n,b", "WINEDEBUG": "fixme-all",
    ]

    @Test func dllOverridesParseLayerAndSerializeDeterministically() throws {
        for text in ["d3d9,d3d10core,d3d11=n;dxgi=b", "d3d10core,d3d11,dxgi,winemetal=b", "d3d11,d3d12,dxgi=b",
                     GamepadBridge.overrides, GamepadBridge.builtinOverrides, "shdocvw=n,b;mscoree=;wow64cpu=b,n"] {
            #expect(try DLLOverrides(parsing: text).serialized == text)
        }
        // Concatenation leftovers, spacing, case, `.dll`, and spelled-out modes are tolerated.
        let tolerant = try DLLOverrides(parsing: ";; D3D11.DLL = n ; dxgi=Native,Builtin;mscoree=disabled;")
        #expect(tolerant.entries.map(\.dll) == ["d3d11", "dxgi", "mscoree"])
        #expect(tolerant["d3d11.dll"] == .native)
        #expect(tolerant.serialized == "d3d11=n;dxgi=n,b;mscoree=")
        // A repeated name keeps its first position; the later mode wins.
        #expect(try DLLOverrides(parsing: "a=n;b=b;a=b").serialized == "a,b=b")
        let layered = try DLLOverrides(parsing: "shdocvw=n,b;dxgi=n").layered(with: DLLOverrides(parsing: "dxgi=b;d3d11=n"))
        #expect(layered.serialized == "shdocvw=n,b;dxgi=b;d3d11=n")
        for invalid in ["d3d11", "=n", "d3d11=x", "d3d11=n,n", "c:\\windows\\d3d11=n", "d3d 11=n", "a,,b=n", ".dll=n"] {
            #expect(throws: MagicWineError.self) { try DLLOverrides(parsing: invalid) }
        }
        let data = try JSONEncoder().encode(["overrides": layered])
        #expect(String(decoding: data, as: UTF8.self) == #"{"overrides":"shdocvw=n,b;dxgi=b;d3d11=n"}"#)
        #expect(try JSONDecoder().decode([String: DLLOverrides].self, from: data)["overrides"] == layered)
    }

    @Test func standardLaunchUsesManagedBaseAndIntegrationsOnly() throws {
        let plan = LaunchPlanner.plan(try Self.request())
        #expect(plan.executable == Self.wine)
        #expect(plan.arguments == [Self.program.path])
        #expect(plan.directory == Self.program.deletingLastPathComponent())
        #expect(plan.environment == Self.standard)
        #expect(plan.warnings == ["skipped"])
    }

    @Test(arguments: [false, true])
    func dxvkEnvironment(showHUD: Bool) throws {
        let component = Self.root.appendingPathComponent("Components/dxvk")
        let folders = GraphicsFolders(cache: Self.prefix.deletingLastPathComponent().appendingPathComponent("graphics/cache"),
                                      logs: Self.root.appendingPathComponent("Logs/B-dxvk"))
        let plan = LaunchPlanner.plan(try Self.request(graphics: .dxvk(component: component, folders: folders, showHUD: showHUD)))
        var expected = Self.standard
        expected["WINEDLLOVERRIDES"] = "shdocvw=n,b;wow64cpu=n;\(Self.xinput)=n,b;d3d9,d3d10core,d3d11=n;dxgi=b"
        expected["WINE_D3D_CONFIG"] = "renderer=vulkan"
        expected["DXVK_CONFIG_FILE"] = component.path + "/dxvk.conf"
        expected["DXVK_STATE_CACHE_PATH"] = folders.cache.path
        expected["DXVK_LOG_PATH"] = folders.logs.path
        if showHUD { expected["DXVK_HUD"] = "version,api,devinfo,fps,frametimes" }
        #expect(plan.environment == expected)
        #expect(plan.executable == Self.wine)
    }

    @Test func metalBackendsRunTheirLoaderWithTheOriginalServer() throws {
        let loader = Self.root.appendingPathComponent("Runtimes/.graphics-views/v/bin/wine")
        let server = Self.wine.deletingLastPathComponent().appendingPathComponent("wineserver")
        let dxmt = Self.root.appendingPathComponent("Components/dxmt")
        let folders = GraphicsFolders(cache: Self.prefix.deletingLastPathComponent().appendingPathComponent("graphics/dxmt-cache"),
                                      logs: Self.root.appendingPathComponent("Logs/B-dxmt"))
        let dxmtPlan = LaunchPlanner.plan(try Self.request(graphics: .metal(
            componentSettings: ["WINEDLLPATH": dxmt.path, "WINEDLLOVERRIDES": "d3d10core,d3d11,dxgi,winemetal=b",
                                "MTL_HUD_ENABLED": "1"],
            loader: loader, server: server, folders: folders)))
        var expected = Self.standard
        expected["WINEDLLOVERRIDES"] = "shdocvw=n,b;wow64cpu=n;\(Self.xinput)=n,b;d3d10core,d3d11,dxgi,winemetal=b"
        expected["WINEDLLPATH"] = dxmt.path
        expected["MTL_HUD_ENABLED"] = "1"
        expected["DXMT_LOG_PATH"] = folders.logs.path
        expected["DXMT_SHADER_CACHE_PATH"] = folders.cache.path
        expected["WINELOADER"] = loader.path
        expected["WINESERVER"] = server.path
        #expect(dxmtPlan.environment == expected)
        #expect(dxmtPlan.executable == loader)
        #expect(dxmtPlan.arguments == [Self.program.path])

        let d3dmetal = Self.root.appendingPathComponent("Components/d3dmetal-abc")
        let shared = d3dmetal.appendingPathComponent("external/libd3dshared.dylib").path
        let metalPlan = LaunchPlanner.plan(try Self.request(graphics: .metal(
            componentSettings: ["WINEDLLPATH": d3dmetal.path + "/wine", "WINEDLLOVERRIDES": "d3d11,d3d12,dxgi=b",
                                "CX_APPLEGPTK_LIBD3DSHARED_PATH": shared, "MTL_HUD_ENABLED": "0"],
            loader: loader, server: server, folders: nil)))
        expected = Self.standard
        expected["WINEDLLOVERRIDES"] = "shdocvw=n,b;wow64cpu=n;\(Self.xinput)=n,b;d3d11,d3d12,dxgi=b"
        expected["WINEDLLPATH"] = d3dmetal.path + "/wine"
        expected["CX_APPLEGPTK_LIBD3DSHARED_PATH"] = shared
        expected["MTL_HUD_ENABLED"] = "0"
        expected["WINELOADER"] = loader.path
        expected["WINESERVER"] = server.path
        #expect(metalPlan.environment == expected)
        #expect(metalPlan.executable == loader)
    }

    @Test func higherLayersWinPerVariableAndPerDLL() throws {
        var request = try Self.request(graphics: .dxvk(component: URL(fileURLWithPath: "/c"),
            folders: GraphicsFolders(cache: URL(fileURLWithPath: "/cache"), logs: URL(fileURLWithPath: "/logs")), showHUD: false))
        // An integration claiming a graphics DLL or variable loses to the backend layer.
        request.integrations?.overrides = try DLLOverrides(parsing: "dxgi=n;d3d11=b;xinput1_3=n,b")
        request.integrations?.environment["WINE_D3D_CONFIG"] = "renderer=gl"
        let plan = LaunchPlanner.plan(request)
        #expect(plan.environment["WINEDLLOVERRIDES"] == "shdocvw=n,b;dxgi=b;d3d11=n;xinput1_3=n,b;d3d9,d3d10core=n")
        #expect(plan.environment["WINE_D3D_CONFIG"] == "renderer=vulkan")
    }

    @Test func customWineKeepsItsSynchronizationAndNoManagedCorrections() throws {
        var request = try Self.request(managed: false)
        request.integrations = nil
        request.inherited["PATH"] = nil
        let environment = LaunchPlanner.plan(request).environment
        #expect(environment == [
            "PATH": Self.wine.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": "/Users/player", "LANG": "en_US.UTF-8", "WINEPREFIX": Self.prefix.path,
            "WINEMSYNC": "1", "WINEESYNC": "1", "WINEFSYNC": "1", "MONO_DEBUG": "existing",
            "WINEDLLOVERRIDES": "shdocvw=n,b", "WINEDEBUG": "fixme-all",
        ])
    }

    @Test func managedSynchronizationAndMonoTLSFollowTheirFacts() throws {
        let off = LaunchPlanner.plan(try Self.request(msync: false)).environment
        #expect(off["WINEMSYNC"] == "0" && off["WINEESYNC"] == "0" && off["WINEFSYNC"] == "0")

        // An older managed Metal revision: Mono TLS correction without MSync ownership.
        var older = try Self.request()
        older.runtime = LaunchRuntimeFacts(managedMSync: false, managedMetal: true)
        older.inherited["MONO_DEBUG"] = "a,use-fallback-tls"
        let environment = LaunchPlanner.plan(older).environment
        #expect(environment["MONO_DEBUG"] == "a,use-fallback-tls")
        #expect(environment["WINEMSYNC"] == "1" && environment["WINEESYNC"] == "1")
        older.inherited["MONO_DEBUG"] = nil
        #expect(LaunchPlanner.plan(older).environment["MONO_DEBUG"] == "use-fallback-tls")
        // Version inspection has no prefix and no Mono program.
        older.prefix = nil
        let inspection = LaunchPlanner.plan(older).environment
        #expect(inspection["MONO_DEBUG"] == nil && inspection["WINEPREFIX"] == nil)
    }

    @Test func programLayerWinsOverBackendAndAppliesArgumentsToEXEOnly() throws {
        let component = URL(fileURLWithPath: "/c")
        var request = try Self.request(graphics: .dxvk(component: component,
            folders: GraphicsFolders(cache: URL(fileURLWithPath: "/cache"), logs: URL(fileURLWithPath: "/logs")), showHUD: true))
        var program = WindowsProgram(name: "Game", executablePath: Self.program.path, arguments: ["-windowed", "a b"],
                                     workingDirectory: "/Users/player/Saves",
                                     environment: ["DXVK_HUD": "fps", "WINE_D3D_CONFIG": "renderer=gl", "WINEDEBUG": "+loaddll"])
        program.dllOverrides = try DLLOverrides(parsing: "dxgi=n;xinput1_3=b;mscoree=")
        request.program = program
        let plan = LaunchPlanner.plan(request)
        #expect(plan.arguments == [Self.program.path, "-windowed", "a b"])
        #expect(plan.directory == URL(fileURLWithPath: "/Users/player/Saves", isDirectory: true))
        #expect(plan.environment["DXVK_HUD"] == "fps")
        #expect(plan.environment["WINE_D3D_CONFIG"] == "renderer=gl")
        #expect(plan.environment["WINEDEBUG"] == "+loaddll")
        #expect(plan.environment["DXVK_CONFIG_FILE"] == "/c/dxvk.conf")
        #expect(plan.environment["WINEDLLOVERRIDES"] ==
                "shdocvw=n,b;wow64cpu=n;xinput1_1,xinput1_2=n,b;xinput1_3=b;xinput1_4,xinput9_1_0=n,b;d3d9,d3d10core,d3d11,dxgi=n;mscoree=")

        // A shortcut gets the environment and load order, never EXE arguments or folder.
        request.arguments = ["start", "/unix", "/drive_c/Game.lnk"]
        request.program = WindowsProgram(name: "Game", executablePath: "/drive_c/Game.lnk", environment: ["DXVK_HUD": "fps"],
                                         dllOverrides: try DLLOverrides(parsing: "dxgi=n"))
        let shortcut = LaunchPlanner.plan(request)
        #expect(shortcut.arguments == ["start", "/unix", "/drive_c/Game.lnk"])
        #expect(shortcut.directory == Self.program.deletingLastPathComponent())
        #expect(shortcut.environment["DXVK_HUD"] == "fps")
        #expect(try DLLOverrides(parsing: shortcut.environment["WINEDLLOVERRIDES"] ?? "")["dxgi"] == .native)
    }

    @Test func wineDebugAndHUDPresetComeFromBottleSwitches() throws {
        var request = try Self.request()
        request.compatibility = CompatibilityOptions(wineDebug: .wineDefault)
        #expect(LaunchPlanner.plan(request).environment["WINEDEBUG"] == nil)
        // Server operations and inspection get no bottle layer at all.
        request.compatibility = nil
        #expect(LaunchPlanner.plan(request).environment["WINEDEBUG"] == nil)

        let folders = GraphicsFolders(cache: URL(fileURLWithPath: "/cache"), logs: URL(fileURLWithPath: "/logs"))
        for (preset, value) in [(CompatibilityOptions.DXVKHUD.fps, "fps"), (.detailed, "version,api,devinfo,fps,frametimes")] {
            request.compatibility = CompatibilityOptions(dxvkHUD: preset)
            request.graphics = .dxvk(component: URL(fileURLWithPath: "/c"), folders: folders, showHUD: true)
            #expect(LaunchPlanner.plan(request).environment["DXVK_HUD"] == value)
            request.graphics = .dxvk(component: URL(fileURLWithPath: "/c"), folders: folders, showHUD: false)
            #expect(LaunchPlanner.plan(request).environment["DXVK_HUD"] == nil)
        }
        // The preset is DXVK's; Metal backends keep their own HUD switch.
        request.graphics = try .metal(componentSettings: ["MTL_HUD_ENABLED": "1"], loader: Self.wine, server: Self.wine, folders: nil)
        #expect(LaunchPlanner.plan(request).environment["DXVK_HUD"] == nil)
    }

    @Test func rosettaAVXFollowsBottleThenProgramAndOnlyWhereSupported() throws {
        var request = try Self.request()
        request.inherited["ROSETTA_ADVERTISE_AVX"] = "1"
        request.runtime.rosettaAVX = true
        #expect(LaunchPlanner.plan(request).environment["ROSETTA_ADVERTISE_AVX"] == nil)
        request.compatibility = CompatibilityOptions(advertiseAVX: true)
        var plan = LaunchPlanner.plan(request)
        #expect(plan.environment["ROSETTA_ADVERTISE_AVX"] == "1")
        #expect(plan.warnings == ["skipped"])

        var program = WindowsProgram(name: "Game", executablePath: Self.program.path, advertiseAVX: false)
        request.program = program
        #expect(LaunchPlanner.plan(request).environment["ROSETTA_ADVERTISE_AVX"] == nil)
        // The program's explicit environment still wins over its own AVX switch.
        program.environment["ROSETTA_ADVERTISE_AVX"] = "1"
        request.program = program
        #expect(LaunchPlanner.plan(request).environment["ROSETTA_ADVERTISE_AVX"] == "1")

        request.compatibility = CompatibilityOptions(advertiseAVX: false)
        request.program = WindowsProgram(name: "Game", executablePath: Self.program.path, advertiseAVX: true)
        #expect(LaunchPlanner.plan(request).environment["ROSETTA_ADVERTISE_AVX"] == "1")

        // Native or pre-macOS 15 Wine: never set, and the user is told why.
        request.runtime.rosettaAVX = false
        plan = LaunchPlanner.plan(request)
        #expect(plan.environment["ROSETTA_ADVERTISE_AVX"] == nil)
        #expect(plan.warnings.count == 2)
        request.program = nil
        #expect(LaunchPlanner.plan(request).warnings == ["skipped"])
    }

    @Test func programDebugWinsOverBottleAndDiagnosticsWinOverBoth() throws {
        var request = try Self.request()
        request.program = WindowsProgram(name: "Game", executablePath: Self.program.path, environment: ["WINEDEBUG": "-all"])
        #expect(LaunchPlanner.plan(request).environment["WINEDEBUG"] == "-all")
        request.diagnostics = true
        let plan = LaunchPlanner.plan(request)
        #expect(plan.environment["WINEDEBUG"] == "+loaddll,+seh,+process")
        #expect(plan.environment["WINEDLLOVERRIDES"] == Self.standard["WINEDLLOVERRIDES"])
    }
}
