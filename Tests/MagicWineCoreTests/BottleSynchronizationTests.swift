import Foundation
import Testing
@testable import MagicWineCore

struct BottleSynchronizationTests {
    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let wine: WineRuntime
        let bottle: Bottle
        var prefix: URL { store.prefixURL(for: bottle) }
        var metadata: URL { prefix.deletingLastPathComponent().appendingPathComponent("bottle.json") }

        init(managed: Bool = true, old: Bool = false) async throws {
            let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            self.paths = paths
            let executable: URL
            if old {
                executable = paths.runtimesDirectory
                    .appendingPathComponent("wine-\(RuntimeInstallation.version)-\(RuntimeInstallation.archiveSHA256.prefix(12))-winemac-wine11.0-metal.6")
                    .appendingPathComponent(RuntimeInstallation.relativeExecutable)
            } else if managed {
                executable = RuntimeInstallation.destination(paths: paths).appendingPathComponent(RuntimeInstallation.relativeExecutable)
            } else {
                executable = paths.root.appendingPathComponent("custom/bin/wine")
            }
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            if [ "$1" = --version ]; then printf 'wine-11.0\\n'; exit 0; fi
            if [ "$1" = wineboot ]; then printf 'WINE REGISTRY Version 2\\n\\n' > "$WINEPREFIX/system.reg"; fi
            if [ "$1" = hold ]; then touch "$WINEPREFIX/holding"; exec /bin/sleep 30; fi
            if [ "$1" = -w ] && [ -f "$WINEPREFIX/external-server" ]; then exec /bin/sleep 30; fi
            if [ "$1" = -k ]; then touch "$WINEPREFIX/killed"; fi
            exit 0
            """
            for url in [executable, executable.deletingLastPathComponent().appendingPathComponent("wineserver")] {
                try Data(script.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            store = BottleStore(paths: paths)
            wine = WineRuntime(paths: paths, store: store)
            bottle = try await store.create(name: "Synchronization", runtime: RuntimeDescriptor(executableURL: executable, version: "wine-11.0"))
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    @Test func defaultsRoundtripLegacyAndInvalidValues() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        #expect(fixture.bottle.msyncEnabled)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata)) as? [String: Any])
        json.removeValue(forKey: "msyncEnabled")
        let legacy = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(Bottle.self, from: legacy).msyncEnabled)
        try legacy.write(to: fixture.metadata)
        #expect(try await fixture.store.current(fixture.bottle).msyncEnabled)
        let invalidValues: [Any] = [NSNull(), "true", 1, [true]]
        for invalid in invalidValues {
            json["msyncEnabled"] = invalid
            let data = try JSONSerialization.data(withJSONObject: json)
            #expect(throws: (any Error).self) { try JSONDecoder().decode(Bottle.self, from: data) }
        }
        for enabled in [false, true] {
            let updated = try await fixture.wine.configureSynchronization(msyncEnabled: enabled, in: fixture.bottle)
            #expect(updated.msyncEnabled == enabled)
            #expect(try await BottleStore(paths: fixture.paths).current(fixture.bottle) == updated)
            #expect(try JSONDecoder().decode(Bottle.self, from: JSONEncoder().encode(updated)) == updated)
        }
    }

    @Test func bypassAndStaleSaveCannotOverwriteSettingsOrRuntime() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var bypass = fixture.bottle
        bypass.msyncEnabled = false
        await #expect(throws: MagicWineError.self) { try await fixture.store.save(bypass) }
        let updated = try await fixture.wine.configureSynchronization(msyncEnabled: false, in: fixture.bottle)
        await #expect(throws: MagicWineError.self) { try await fixture.store.save(fixture.bottle) }
        var changedRuntime = updated
        changedRuntime.runtime = RuntimeDescriptor(executableURL: URL(fileURLWithPath: "/tmp/foreign-wine"), version: "wine-11")
        await #expect(throws: MagicWineError.self) { try await fixture.store.save(changedRuntime) }
        #expect(try await fixture.store.current(fixture.bottle) == updated)
    }

    @Test func environmentOwnsManagedSynchronizationOnly() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let inherited = ["WINEMSYNC": "inherited", "WINEESYNC": "1", "WINEFSYNC": "1", "WINEPREFIX": "/wrong", "MONO_DEBUG": "existing"]
        for enabled in [false, true] {
            let environment = fixture.wine.environment(executable: fixture.bottle.runtime.executableURL,
                prefix: fixture.prefix, msyncEnabled: enabled, inherited: inherited)
            #expect(environment["WINEMSYNC"] == (enabled ? "1" : "0"))
            #expect(environment["WINEESYNC"] == "0")
            #expect(environment["WINEFSYNC"] == "0")
            #expect(environment["WINEPREFIX"] == fixture.prefix.path)
            #expect(environment["MONO_DEBUG"] == "existing,use-fallback-tls")
        }
        for executable in [URL(fileURLWithPath: "/opt/custom/bin/wine"),
            URL(fileURLWithPath: fixture.bottle.runtime.executableURL.path.replacingOccurrences(of: "metal.7", with: "metal.6"))] {
            let environment = fixture.wine.environment(executable: executable, prefix: fixture.prefix, inherited: inherited)
            #expect(environment["WINEMSYNC"] == "inherited")
            #expect(environment["WINEESYNC"] == "1")
            #expect(environment["WINEFSYNC"] == "1")
            let clean = fixture.wine.environment(executable: executable, prefix: fixture.prefix, inherited: [:])
            #expect(clean["WINEMSYNC"] == nil)
            #expect(clean["WINEESYNC"] == nil)
            #expect(clean["WINEFSYNC"] == nil)
        }
        let alias = fixture.paths.root.appendingPathComponent("wine-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.bottle.runtime.executableURL)
        #expect(fixture.wine.supportsMSync(RuntimeDescriptor(executableURL: alias, version: "arbitrary")))
    }


    @Test(arguments: [GraphicsOperationLease.Kind.launch, .lifetime])
    func crossProcessLeaseRejectsChangeWithoutStopping(kind: GraphicsOperationLease.Kind) async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let lease = try await GraphicsOperationLease.acquire(paths: fixture.paths, bottleID: fixture.bottle.id,
            kind: kind, exclusive: false)
        defer { lease.release() }
        await #expect(throws: MagicWineError.self) {
            try await fixture.wine.configureSynchronization(msyncEnabled: false, in: fixture.bottle)
        }
        #expect(try await fixture.store.current(fixture.bottle).msyncEnabled)
        #expect(!FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("killed").path))
    }

    @Test func detachedServerRejectsChangeWithoutKillingServer() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let marker = fixture.prefix.appendingPathComponent("external-server")
        try Data().write(to: marker)
        await #expect(throws: MagicWineError.self) {
            try await fixture.wine.configureSynchronization(msyncEnabled: false, in: fixture.bottle)
        }
        #expect(try await fixture.store.current(fixture.bottle).msyncEnabled)
        #expect(!FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("killed").path))
        try FileManager.default.removeItem(at: marker)
        #expect(try await !fixture.wine.configureSynchronization(msyncEnabled: false, in: fixture.bottle).msyncEnabled)
    }

    @Test func activeProgramRejectsChangeUntilStopped() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let task = Task { try await fixture.wine.run(arguments: ["hold"], in: fixture.bottle) }
        defer { task.cancel() }
        let marker = fixture.prefix.appendingPathComponent("holding")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        await #expect(throws: MagicWineError.self) {
            try await fixture.wine.configureSynchronization(msyncEnabled: false, in: fixture.bottle)
        }
        #expect(try await fixture.store.current(fixture.bottle).msyncEnabled)
        #expect(!FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("killed").path))
        _ = try await fixture.wine.stop(fixture.bottle)
        _ = try? await task.value
        #expect(try await !fixture.wine.configureSynchronization(msyncEnabled: false, in: fixture.bottle).msyncEnabled)
    }

    @Test(arguments: [false, true])
    func unsupportedRuntimeCannotClaimMSyncOrSilentlyUpgrade(old: Bool) async throws {
        let fixture = try await Fixture(managed: false, old: old)
        defer { fixture.remove() }
        #expect(!fixture.wine.supportsMSync(fixture.bottle.runtime))
        #expect(fixture.wine.canUpgradeRuntime(fixture.bottle.runtime) == old)
        // An older managed runtime is fixed by updating Wine; custom Wine only by another bottle.
        let msync = try #require(await thrownError {
            _ = try await fixture.wine.configureSynchronization(msyncEnabled: false, in: fixture.bottle)
        })
        guard case .runtimeIncompatible = msync else { Issue.record("Unexpected error: \(msync)"); return }
        #expect(msync.recoveryActions == [old ? .updateWine : .chooseWine])
        let upgrade = try #require(await thrownError { _ = try await fixture.wine.upgradeRuntime(in: fixture.bottle) })
        // The old bottle may upgrade, but the updated runtime is not installed yet.
        #expect(upgrade.recoveryActions == [old ? .updateWine : .chooseWine])
        #expect(try await fixture.store.current(fixture.bottle) == fixture.bottle)
        #expect(!FileManager.default.fileExists(atPath: RuntimeInstallation.destination(paths: fixture.paths).path))
    }

    @Test func explicitUpgradeRejectsBusyAndUnvalidatedInstallations() async throws {
        let fixture = try await Fixture(old: true)
        defer { fixture.remove() }
        let lease = try await GraphicsOperationLease.acquire(paths: fixture.paths, bottleID: fixture.bottle.id,
            kind: .lifetime, exclusive: false)
        await #expect(throws: MagicWineError.self) { try await fixture.wine.upgradeRuntime(in: fixture.bottle) }
        lease.release()
        let replacement = RuntimeInstallation.destination(paths: fixture.paths)
            .appendingPathComponent(RuntimeInstallation.relativeExecutable)
        try FileManager.default.createDirectory(at: replacement.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nprintf 'wine-11.0\\n'\n".utf8).write(to: replacement)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: replacement.path)
        await #expect(throws: (any Error).self) { try await fixture.wine.upgradeRuntime(in: fixture.bottle) }
        #expect(try await fixture.store.current(fixture.bottle) == fixture.bottle)
        #expect(!FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("killed").path))
    }
}
