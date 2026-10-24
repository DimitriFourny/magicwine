import Foundation
import Testing
@testable import MagicWineCore

struct BottleInitializationTests {
    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let wine: WineRuntime
        let bottle: Bottle
        var prefix: URL { store.prefixURL(for: bottle) }
        var directory: URL { prefix.deletingLastPathComponent() }

        /// The fake Wine creates `system.reg` and `user.reg`, or nothing when `incompleteRegistry`.
        /// With `lingeringServer`, setup also stages a DLL move for `wineboot --init` (each boot
        /// is counted in `boots`), and `wineserver -w` after setup's `wineboot` keeps waiting
        /// until `wineserver -k` (noted in `killed`).
        init(incompleteRegistry: Bool = false, lingeringServer: Bool = false) async throws {
            let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            self.paths = paths
            let executable = paths.root.appendingPathComponent("custom/bin/wine")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let registries = incompleteRegistry ? ":" :
                "for name in system user; do printf 'WINE REGISTRY Version 2\\n\\n' > \"$WINEPREFIX/$name.reg\"; done"
            let script = lingeringServer ? #"""
            #!/bin/sh
            state="$WINEPREFIX/.."
            case "$1" in
              --version) printf 'wine-11.0\n' ;;
              wineboot)
                if [ "$2" = --init ]; then
                  echo boot >> "$state/boots"; printf 'WINE REGISTRY Version 2\n\n' > "$WINEPREFIX/system.reg"; exit 0
                fi
                printf 'WINE REGISTRY Version 2\n\n' > "$WINEPREFIX/user.reg"
                printf '%s\n' 'WINE REGISTRY Version 2' '' \
                  '[System\\ControlSet001\\Control\\Session Manager] 1792842028' \
                  '"PendingFileRenameOperations"=str(7):"\\??\\C:\\windows\\system32\\dll1.tmp\0!\\??\\C:\\windows\\system32\\wow64cpu.dll\0"' \
                  > "$WINEPREFIX/system.reg"
                touch "$state/server" ;;
              -k) rm -f "$state/server"; touch "$state/killed" ;;
              -w) [ -f "$state/server" ] || exit 0
                  touch "$state/waiting"; i=0
                  while [ -f "$state/server" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i + 1)); done ;;
            esac
            exit 0
            """# : """
            #!/bin/sh
            if [ "$1" = --version ]; then printf 'wine-11.0\\n'; exit 0; fi
            if [ "$1" = wineboot ]; then \(registries); fi
            exit 0
            """
            for url in [executable, executable.deletingLastPathComponent().appendingPathComponent("wineserver")] {
                try Data(script.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            store = BottleStore(paths: paths)
            wine = WineRuntime(paths: paths, store: store)
            bottle = try await store.create(name: "Initialization", runtime: RuntimeDescriptor(executableURL: executable, version: "wine-11.0"))
        }

        func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
        var boots: Int {
            ((try? String(contentsOf: directory.appendingPathComponent("boots"), encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    @Test func initializePersistsTheInitializedStateAndKeepsConcurrentEdits() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(!fixture.bottle.isInitialized)
        // An edit saved while setup runs is not lost by the stale copy handed to setup.
        let program = fixture.paths.root.appendingPathComponent("tool.exe")
        try Data("MZ".utf8).write(to: program)
        let edited = try await fixture.store.registerProgram(in: fixture.bottle, executableURL: program)

        let initialization = try await fixture.wine.initialize(fixture.bottle)
        #expect(initialization.bottle.isInitialized)
        #expect(initialization.bottle.programs == edited.programs)
        #expect(initialization.result.exitCode == 0)
        #expect(try await BottleStore(paths: fixture.paths).list() == [initialization.bottle])

        // Retrying setup on an initialized bottle succeeds and changes nothing.
        let again = try await fixture.wine.initialize(initialization.bottle)
        #expect(again.bottle == initialization.bottle)
    }

    @Test func initializeWithoutAFullRegistryLeavesTheBottleUninitialized() async throws {
        let fixture = try await Fixture(incompleteRegistry: true)
        defer { fixture.remove() }
        await #expect(throws: MagicWineError.self) { try await fixture.wine.initialize(fixture.bottle) }
        #expect(try await fixture.store.current(fixture.bottle).isInitialized == false)
    }

    @Test func stopDuringTheSetupServerWaitAbortsSetup() async throws {
        let fixture = try await Fixture(lingeringServer: true)
        defer { fixture.remove() }
        let setup = Task { try await fixture.wine.initialize(fixture.bottle) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !fixture.exists("waiting"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fixture.exists("waiting"))

        try await fixture.wine.stop(fixture.bottle)
        // Setup ends as stopped: it boots no new Wine session after Stop and stays retryable.
        await #expect { try await setup.value } throws: { error in
            if case MagicWineError.stopped = error { return true }
            return false
        }
        #expect(fixture.boots == 0)
        #expect(try await fixture.store.current(fixture.bottle).isInitialized == false)
    }

    @Test func setupServerWaitTimeoutStopsWine() async throws {
        let fixture = try await Fixture(lingeringServer: true)
        defer { fixture.remove() }
        await #expect {
            try await fixture.wine.initialize(fixture.bottle, timeout: 2)
        } throws: { error in
            if case MagicWineError.timedOut = error { return true }
            return false
        }
        #expect(fixture.exists("killed"))
        #expect(fixture.boots == 0)
        #expect(try await fixture.store.current(fixture.bottle).isInitialized == false)
    }

    @Test func generalSaveCannotChangeTheInitializedState() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var forced = fixture.bottle
        forced.isInitialized = true
        await #expect(throws: MagicWineError.self) { try await fixture.store.save(forced) }
        #expect(try await fixture.store.current(fixture.bottle).isInitialized == false)

        let initialized = try await fixture.store.markInitialized(fixture.bottle)
        var cleared = initialized
        cleared.isInitialized = false
        await #expect(throws: MagicWineError.self) { try await fixture.store.save(cleared) }
        #expect(try await fixture.store.current(fixture.bottle).isInitialized)
        // An unchanged flag still saves.
        try await fixture.store.save(initialized)
    }
}
