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
            if [ "$1" = start ]; then case "$3" in *fail*) exit 1 ;; esac; exit 0; fi
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

    @Test func programExitCodeIsResultWhileSetupAndDispatchFailuresThrow() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let result = try await fixture.wine.launch(try fixture.program("exit-3.exe"), in: fixture.bottle)
        #expect(result.exitCode == 3)
        #expect(FileManager.default.fileExists(atPath: result.logURL.path))

        do {
            _ = try await fixture.wine.launch(try fixture.program("dispatch-fail.url"), in: fixture.bottle)
            Issue.record("A failed shortcut dispatch must remain an error.")
        } catch MagicWineError.processFailed(let code, _) {
            #expect(code == 1)
        }
        do {
            _ = try await fixture.wine.run(arguments: ["exit-4.exe"], in: fixture.bottle)
            Issue.record("Wine commands keep error semantics for nonzero status.")
        } catch MagicWineError.processFailed(let code, _) {
            #expect(code == 4)
        }
        do {
            _ = try await fixture.wine.initialize(fixture.bottle)
            Issue.record("Bottle setup must fail on a nonzero wineboot status.")
        } catch MagicWineError.processFailed(let code, _) {
            #expect(code == 7)
        }
    }

    @Test func logSummaryReportsOnlyTheLastWineErrorsInABoundedTail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("program.log")
        #expect(ProcessLogSummary.summary(at: log) == nil)

        try Data("""
        Command: "wine" "game.exe"

        0024:err:module:first
        0024:fixme:ntdll:ignored
        0024:err:module:second\r
        err:winediag:third
        0030:err:d3d:fourth
        0030:trace:ignored

        """.utf8).write(to: log)
        #expect(ProcessLogSummary.summary(at: log) == "0024:err:module:second\nerr:winediag:third\n0030:err:d3d:fourth")
        #expect(ProcessLogSummary.summary(at: log, maximumLines: 1) == "0030:err:d3d:fourth")

        let link = root.appendingPathComponent("linked.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: log)
        #expect(ProcessLogSummary.summary(at: link) == nil)

        try Data("fixme:only\n".utf8).write(to: log)
        #expect(ProcessLogSummary.summary(at: log) == nil)

        // An error outside the tail is never read; an overlong line is shortened.
        let long = "0024:err:module:" + String(repeating: "x", count: 1_000)
        let filler = String(repeating: "0024:fixme:filler\n", count: 20_000)
        try Data(("0024:err:module:early\n" + filler + long + "\n").utf8).write(to: log)
        let summary = try #require(ProcessLogSummary.summary(at: log))
        #expect(!summary.contains("early"))
        #expect(summary.hasPrefix("0024:err:module:xxx"))
        #expect(summary.count == ProcessLogSummary.lineLimit)

        // The tail starts inside a line: its matching fragment is not reported.
        let rest = ":err:fragment\n"
        let padding = String(repeating: "f", count: ProcessLogSummary.tailBytes + 1 - rest.utf8.count - 1) + "\n"
        try Data(("0024" + rest + padding).utf8).write(to: log)
        #expect(ProcessLogSummary.summary(at: log) == nil)
    }

    @Test func hudChangeWhileProgramRunsNeitherStopsItNorTouchesThePrefix() async throws {
        let fixture = try await Fixture(initialized: false)
        defer { fixture.remove() }
        let finished = Box<Bool>()
        let task = Task {
            _ = try? await fixture.wine.run(arguments: ["hold"], in: fixture.bottle)
            finished.set(true)
        }
        defer { task.cancel() }
        let marker = fixture.prefix.appendingPathComponent("holding")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))

        // A bottle previously configured for DXVK; the running program holds a lifetime lease.
        let metadata = fixture.directory.appendingPathComponent("bottle.json")
        func write(_ graphics: GraphicsConfiguration) throws -> Bottle {
            var bottle = try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: metadata))
            bottle.isInitialized = true
            bottle.graphics = graphics
            try JSONEncoder().encode(bottle).write(to: metadata, options: .atomic)
            return bottle
        }
        let dxvk = try write(GraphicsConfiguration(backend: .dxvk, componentID: DXVKInstallation.componentID))
        let prefixBefore = try FileManager.default.subpathsOfDirectory(atPath: fixture.prefix.path).sorted()

        let updated = try await fixture.wine.setGraphicsHUD(true, in: dxvk)
        #expect(updated.graphics == GraphicsConfiguration(backend: .dxvk, componentID: DXVKInstallation.componentID, showHUD: true))
        let saved = try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: metadata))
        #expect(saved.graphics.showHUD)
        #expect(saved.programs == dxvk.programs && saved.runtime == dxvk.runtime)
        #expect(try await BottleStore(paths: fixture.paths).current(dxvk).graphics.showHUD)
        #expect(try await !fixture.wine.setGraphicsHUD(false, in: updated).graphics.showHUD)

        // A stale view of the backend cannot attach a HUD to a selection it never saw.
        var stale = dxvk
        stale.graphics = GraphicsConfiguration(backend: .dxmt, componentID: DXMTInstallation.componentID)
        await #expect(throws: MagicWineError.self) { try await fixture.wine.setGraphicsHUD(true, in: stale) }

        let legacy = try write(GraphicsConfiguration(backend: .dxvk, componentID: "dxvk-unsupported"))
        await #expect(throws: MagicWineError.self) { try await fixture.wine.setGraphicsHUD(true, in: legacy) }
        let standard = try write(GraphicsConfiguration())
        await #expect(throws: MagicWineError.self) { try await fixture.wine.setGraphicsHUD(true, in: standard) }
        #expect(try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: metadata)).graphics == GraphicsConfiguration())

        #expect(finished.value == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("killed").path))
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.prefix.path).sorted() == prefixBefore)
        _ = try await fixture.wine.stop(fixture.bottle)
        _ = await task.value
    }
}
