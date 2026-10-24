import Foundation
import Testing
@testable import MagicWineCore

struct ProgramLaunchOptionsTests {
    @Test func legacyProgramsDecodeWithEmptyOptionsAndKeepTheirShape() throws {
        let id = UUID()
        let legacy = Data(#"{"id":"\#(id.uuidString)","name":"Steam","executablePath":"/drive_c/Steam.lnk"}"#.utf8)
        let program = try JSONDecoder().decode(WindowsProgram.self, from: legacy)
        #expect(program == WindowsProgram(id: id, name: "Steam", executablePath: "/drive_c/Steam.lnk"))
        #expect(program.arguments.isEmpty && program.workingDirectory == nil)
        #expect(program.environment.isEmpty && program.dllOverrides.isEmpty)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let keys = try #require(JSONSerialization.jsonObject(with: encoder.encode(program)) as? [String: Any]).keys
        #expect(Set(keys) == ["id", "name", "executablePath"])

        let edited = WindowsProgram(id: id, name: "Game", executablePath: "/drive_c/game.exe", arguments: ["-a", "b c"],
                                    workingDirectory: "/tmp", environment: ["WINEDEBUG": "-all"],
                                    dllOverrides: try DLLOverrides(parsing: "d3d11=n;mscoree="))
        #expect(try JSONDecoder().decode(WindowsProgram.self, from: encoder.encode(edited)) == edited)
        let invalid = Data(#"{"id":"\#(id.uuidString)","name":"x","executablePath":"/x.exe","dllOverrides":"d3d11=q"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(WindowsProgram.self, from: invalid) }
    }

    @Test func environmentKeysThatBreakIsolationOrPinsAreRefused() throws {
        for key in ["WINEPREFIX", "WINELOADER", "WINESERVER", "WINEDLLPATH", "WINEDLLOVERRIDES", "WINEARCH", "WINEMSYNC",
                    "WINEESYNC", "PATH", "DYLD_INSERT_LIBRARIES", "MAGICWINE_GAMEPAD_STATE", "MAGICWINE_ANYTHING",
                    "CX_APPLEGPTK_LIBD3DSHARED_PATH", "", "1ABC", "A-B", "A=B", "A B"] {
            #expect(WindowsProgram.environmentKeyProblem(key) != nil, "\(key)")
            let program = WindowsProgram(name: "Game", executablePath: "/game.exe", environment: [key: "1"])
            #expect(throws: MagicWineError.self) { try program.validateLaunchOptions() }
        }
        for key in ["WINEDEBUG", "WINE_D3D_CONFIG", "DXVK_HUD", "DXVK_ASYNC", "MTL_HUD_ENABLED", "DXMT_LOG_LEVEL",
                    "MONO_DEBUG", "SteamAppId", "_private"] {
            #expect(WindowsProgram.environmentKeyProblem(key) == nil, "\(key)")
        }
        #expect(WindowsProgram.environmentValueProblem("a\0b") != nil)
        #expect(WindowsProgram.environmentValueProblem(String(repeating: "x", count: 4097)) != nil)
        #expect(WindowsProgram.environmentValueProblem("C:\\Games;a=b") == nil)
    }

    @Test func argumentsAndFolderApplyToEXEOnlyAndFolderMustExistAtLaunch() throws {
        try WindowsProgram(name: "Game", executablePath: "/drive_c/game.EXE", arguments: ["-x"], workingDirectory: "/tmp")
            .validateLaunchOptions()
        for path in ["/drive_c/Game.lnk", "/drive_c/Game.url"] {
            #expect(throws: MagicWineError.self) {
                try WindowsProgram(name: "Game", executablePath: path, arguments: ["-x"]).validateLaunchOptions()
            }
            #expect(throws: MagicWineError.self) {
                try WindowsProgram(name: "Game", executablePath: path, workingDirectory: "/tmp").validateLaunchOptions()
            }
            try WindowsProgram(name: "Game", executablePath: path, environment: ["WINEDEBUG": "-all"]).validateLaunchOptions()
        }
        #expect(throws: MagicWineError.self) {
            try WindowsProgram(name: "Game", executablePath: "/game.exe", workingDirectory: "relative/folder").validateLaunchOptions()
        }
        #expect(throws: MagicWineError.self) {
            try WindowsProgram(name: "Game", executablePath: "/game.exe", arguments: ["a\0b"]).validateLaunchOptions()
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        #expect(try WindowsProgram(name: "G", executablePath: "/g.exe", workingDirectory: root.path).launchDirectory() != nil)
        #expect(try WindowsProgram(name: "G", executablePath: "/g.exe").launchDirectory() == nil)
        for missing in [file.path, root.appendingPathComponent("missing").path] {
            #expect(throws: MagicWineError.self) {
                try WindowsProgram(name: "G", executablePath: "/g.exe", workingDirectory: missing).launchDirectory()
            }
        }
    }

    @Test func argumentTextParsesLikeAShellWithLiteralBackslashes() throws {
        #expect(try WindowsProgram.parseArguments("  -windowed   -path C:\\Games\\x  ") == ["-windowed", "-path", "C:\\Games\\x"])
        #expect(try WindowsProgram.parseArguments(#"-config "My Settings.ini" 'it''s' "" "a\"b\\c\d""#) ==
                ["-config", "My Settings.ini", "its", "", #"a"b\c\d"#])
        #expect(try WindowsProgram.parseArguments("") == [])
        #expect(throws: MagicWineError.self) { try WindowsProgram.parseArguments("-name \"unterminated") }
        #expect(throws: MagicWineError.self) { try WindowsProgram.parseArguments("'open") }
        let samples: [[String]] = [[], ["-x"], ["a b", "", "C:\\Program Files\\Game\\"], ["it's \"quoted\" \\"], ["tab\there"]]
        for arguments in samples {
            #expect(try WindowsProgram.parseArguments(WindowsProgram.formatArguments(arguments)) == arguments)
        }
    }

    @Test func dllOverrideModesAndNamesAreValidated() throws {
        #expect(try DLLOverrides.Mode(parsing: "N,B") == .nativeThenBuiltin)
        #expect(try DLLOverrides.Mode(parsing: "builtin,native") == .builtinThenNative)
        #expect(try DLLOverrides.Mode(parsing: "disabled") == .disabled)
        for mode in ["x", "n,n", "nb", "n;b", "n,b,n"] {
            #expect(throws: MagicWineError.self) { try DLLOverrides.Mode(parsing: mode) }
        }
        var overrides = DLLOverrides()
        for name in ["", "C:\\x\\d3d11", "../d3d11", "d3d11;dxgi", "a=b", "d3d 11", String(repeating: "a", count: 65)] {
            #expect(throws: MagicWineError.self) { try overrides.set(.native, for: name) }
        }
        try overrides.set(.native, for: "D3D11.dll")
        overrides.remove("d3d11")
        #expect(overrides.isEmpty)
    }

    @Test func programGraphicsPersistsOnlyWhenChosenAndNamesAComponentOnlyForD3DMetal() throws {
        let id = UUID()
        let legacy = Data(#"{"id":"\#(id.uuidString)","name":"Game","executablePath":"/drive_c/game.exe"}"#.utf8)
        #expect(try JSONDecoder().decode(WindowsProgram.self, from: legacy).graphics == nil)

        let d3dmetal = "d3dmetal-" + String(repeating: "0a", count: 32)
        for graphics in [ProgramGraphics.standard, ProgramGraphics(backend: .dxvk), ProgramGraphics(backend: .dxmt),
                         ProgramGraphics(backend: .d3dmetal, componentID: d3dmetal)] {
            let program = WindowsProgram(id: id, name: "Game", executablePath: "/drive_c/game.exe", graphics: graphics)
            try program.validateLaunchOptions()
            let data = try JSONEncoder().encode(program)
            #expect(try JSONDecoder().decode(WindowsProgram.self, from: data) == program)
            let stored = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect((stored["graphics"] as? [String: Any])?["backend"] as? String == graphics.backend.rawValue)
        }
        // Backends that use the bottle's prefix files have no component; D3DMetal needs a supported one.
        for invalid in [ProgramGraphics(backend: .standard, componentID: d3dmetal),
                        ProgramGraphics(backend: .dxvk, componentID: DXVKInstallation.componentID),
                        ProgramGraphics(backend: .dxmt, componentID: DXMTInstallation.componentID),
                        ProgramGraphics(backend: .d3dmetal), ProgramGraphics(backend: .d3dmetal, componentID: "d3dmetal-x")] {
            let program = WindowsProgram(name: "Game", executablePath: "/drive_c/game.exe", graphics: invalid)
            #expect(throws: MagicWineError.self) { try program.validateLaunchOptions() }
        }
    }
}
