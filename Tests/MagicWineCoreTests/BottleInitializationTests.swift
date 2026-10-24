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

        /// The fake Wine creates `system.reg` and `user.reg`, or nothing when `incompleteRegistry`.
        init(incompleteRegistry: Bool = false) async throws {
            let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            self.paths = paths
            let executable = paths.root.appendingPathComponent("custom/bin/wine")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let registries = incompleteRegistry ? ":" :
                "for name in system user; do printf 'WINE REGISTRY Version 2\\n\\n' > \"$WINEPREFIX/$name.reg\"; done"
            let script = """
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
