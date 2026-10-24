import CryptoKit
import Foundation
import Testing
@testable import MagicWineCore

struct LaunchTests {
    private final class Box<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        var value: Value? { lock.withLock { stored } }
        func set(_ value: Value) { lock.withLock { stored = value } }
    }

    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let wine: WineRuntime
        let bottle: Bottle
        var prefix: URL { store.prefixURL(for: bottle) }
        var directory: URL { prefix.deletingLastPathComponent() }
        var environmentDump: URL { prefix.appendingPathComponent("launch-environment") }

        /// A fake Wine records a direct EXE launch's environment; `exit-N.exe` exits with N.
        init(initialized: Bool = true) async throws {
            let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            self.paths = paths
            let executable = paths.root.appendingPathComponent("custom/bin/wine")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            if [ "$1" = --version ]; then printf 'wine-11.0\\n'; exit 0; fi
            if [ "$1" = wineboot ]; then exit 7; fi
            if [ "$1" = hold ]; then touch "$WINEPREFIX/holding"; exec /bin/sleep 30; fi
            if [ "$1" = -k ]; then touch "$WINEPREFIX/killed"; fi
            case "$1" in
              *exit-*.exe) env > "$WINEPREFIX/launch-environment"; code="${1##*exit-}"; exit "${code%.exe}" ;;
              *.exe) env > "$WINEPREFIX/launch-environment" ;;
            esac
            exit 0
            """
            for url in [executable, executable.deletingLastPathComponent().appendingPathComponent("wineserver")] {
                try Data(script.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            store = BottleStore(paths: paths)
            wine = WineRuntime(paths: paths)
            var bottle = try await store.create(name: "Launch", runtime: RuntimeDescriptor(executableURL: executable, version: "wine-11.0"))
            let prefix = store.prefixURL(for: bottle)
            for folder in ["system32", "syswow64"] {
                try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/" + folder),
                                                        withIntermediateDirectories: true)
            }
            if initialized {
                bottle.isInitialized = true
                try await store.save(bottle)
            }
            self.bottle = bottle
        }

        func program(_ name: String) throws -> WindowsProgram {
            let url = prefix.appendingPathComponent("drive_c/" + name)
            try Data("MZ".utf8).write(to: url)
            return WindowsProgram(name: name, executablePath: url.path)
        }

        func launchEnvironment() throws -> [String: String] {
            let text = try String(contentsOf: environmentDump, encoding: .utf8)
            var result: [String: String] = [:]
            for line in text.split(separator: "\n") {
                guard let separator = line.firstIndex(of: "=") else { continue }
                result[String(line[..<separator])] = String(line[line.index(after: separator)...])
            }
            return result
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    @Test func customXInputDLLLaunchesWithBuiltinXInputAndEarlyWarning() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let custom = Data("user-installed controller middleware".utf8)
        let dll = fixture.prefix.appendingPathComponent("drive_c/windows/system32/xinput1_3.dll")
        try custom.write(to: dll)
        let started = Box<LaunchStart>()
        let result = try await fixture.wine.launch(try fixture.program("game.exe"), in: fixture.bottle) { started.set($0) }

        #expect(result.exitCode == 0)
        let start = try #require(started.value)
        #expect(start.logURL == result.logURL)
        #expect(start.warnings.count == 1)
        let log = try String(contentsOf: result.logURL, encoding: .utf8)
        for warning in start.warnings { #expect(log.contains(warning)) }
        let environment = try fixture.launchEnvironment()
        let overrides = try #require(environment["WINEDLLOVERRIDES"]).split(separator: ";").map(String.init)
        #expect(overrides.contains(GamepadBridge.builtinOverrides))
        #expect(!overrides.contains(GamepadBridge.overrides))
        #expect(!overrides.contains("wow64cpu=n"))
        #expect(environment["MAGICWINE_GAMEPAD_STATE"] == nil)
        // The failed bridge left the prefix exactly as it found it.
        #expect(try Data(contentsOf: dll) == custom)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory
            .appendingPathComponent("runtime-compatibility/\(GamepadBridge.componentID)").path))
        for name in GamepadBridge.dllNames where name != "xinput1_3" {
            #expect(!FileManager.default.fileExists(atPath: fixture.prefix
                .appendingPathComponent("drive_c/windows/system32/\(name).dll").path))
        }
    }

    @Test func customWow64CPUSkipsOnlyTheRepair() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = root.appendingPathComponent("Managed/Bottles/fixture", isDirectory: true)
        let prefix = bottle.appendingPathComponent("prefix", isDirectory: true)
        let destination = prefix.appendingPathComponent("drive_c/windows/system32/wow64cpu.dll")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let custom = Data("custom CPU module".utf8)
        try custom.write(to: destination)
        let digest = SHA256.hash(data: Data("stock CPU module".utf8)).map { String(format: "%02x", $0) }.joined()
        let resource = root.appendingPathComponent("unused")
        let payload = RosettaCPUCompatibility.Payload(dll: resource, source: resource, license: resource,
                                                      dllSHA256: digest, sourceSHA256: digest, licenseSHA256: digest)
        let state = ["MAGICWINE_GAMEPAD_STATE": "Z:\\state"]

        let integrations = try WineRuntime.prepareIntegrations(gamepad: .success(state), rosetta: {
            try RosettaCPUCompatibility.install(prefix: prefix, bottleDirectory: bottle, payload: payload, originalSHA256: digest)
        }, bridge: { GamepadBridge.overrides })

        #expect(integrations.overrides == [GamepadBridge.overrides])
        #expect(integrations.environment == state)
        #expect(integrations.warnings.count == 1)
        #expect(try Data(contentsOf: destination) == custom)
        #expect(!FileManager.default.fileExists(atPath: bottle.appendingPathComponent("runtime-compatibility").path))
    }

    @Test func controllerServiceFailureNeverTouchesThePrefixBridge() throws {
        var bridgeCalled = false
        let integrations = try WineRuntime.prepareIntegrations(
            gamepad: .failure(GamepadError.invalidConfiguration("unreadable profiles")),
            rosetta: { true }, bridge: { bridgeCalled = true; return GamepadBridge.overrides })
        #expect(!bridgeCalled)
        #expect(integrations.overrides == ["wow64cpu=n", GamepadBridge.builtinOverrides])
        #expect(integrations.environment.isEmpty)
        #expect(integrations.warnings.count == 1)
    }

    @Test func cancellationAndStopStillAbortTheLaunch() {
        let stopped = MagicWineError.stopped(logURL: URL(fileURLWithPath: "/tmp/stopped.log"))
        #expect(throws: CancellationError.self) {
            try WineRuntime.prepareIntegrations(gamepad: .success([:]), rosetta: { throw CancellationError() },
                                                bridge: { GamepadBridge.overrides })
        }
        #expect(throws: CancellationError.self) {
            try WineRuntime.prepareIntegrations(gamepad: .success([:]), rosetta: { false },
                                                bridge: { throw CancellationError() })
        }
        #expect(throws: MagicWineError.self) {
            try WineRuntime.prepareIntegrations(gamepad: .failure(stopped), rosetta: { false },
                                                bridge: { GamepadBridge.overrides })
        }
    }
}
