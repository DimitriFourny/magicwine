import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct StorageCleanupTests {
    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let outside: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString)
            paths = ApplicationPaths(root: base.appendingPathComponent("Library"))
            try paths.prepare()
            store = BottleStore(paths: paths)
            outside = base.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: outside.appendingPathComponent("user-file"))
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root.deletingLastPathComponent()) }

        func runtimeName(_ revision: Int) -> String {
            "wine-\(RuntimeInstallation.version)-\(RuntimeInstallation.archiveSHA256.prefix(12))-winemac-wine11.0-metal.\(revision)"
        }

        func executable(_ revision: Int) -> URL {
            paths.runtimesDirectory.appendingPathComponent(runtimeName(revision))
                .appendingPathComponent(RuntimeInstallation.relativeExecutable)
        }

        /// A fake runtime layout that is complete enough for a private DXMT view.
        @discardableResult
        func runtime(_ revision: Int) throws -> URL {
            let wine = executable(revision)
            let script = """
            #!/bin/sh
            if [ "$1" = -w ] && [ -f "$WINEPREFIX/external-server" ]; then exec /bin/sleep 30; fi
            exit 0
            """
            for url in [wine, wine.deletingLastPathComponent().appendingPathComponent("wineserver")] {
                try write(Data(script.utf8), to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try write(Data("ntdll".utf8), to: wine.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("lib/wine/x86_64-unix/ntdll.so"))
            return wine
        }

        func component(_ id: String) throws -> URL {
            let root = paths.componentsDirectory.appendingPathComponent(id, isDirectory: true)
            for architecture in ["x86_64-windows", "i386-windows"] {
                for name in ["d3d10core", "d3d11", "dxgi", "winemetal"] {
                    try write(Data("\(id) \(architecture) \(name)".utf8), to: root.appendingPathComponent("\(architecture)/\(name).dll"))
                }
            }
            try write(Data("\(id) winemetal.so".utf8), to: root.appendingPathComponent("x86_64-unix/winemetal.so"))
            return root
        }

        func view(_ revision: Int, component: String) throws -> URL {
            try GraphicsRuntimeView.prepare(executable: executable(revision),
                                            component: paths.componentsDirectory.appendingPathComponent(component, isDirectory: true),
                                            backend: .dxmt, paths: paths)
                .deletingLastPathComponent().deletingLastPathComponent()
        }

        func bottle(_ name: String, revision: Int, componentID: String? = nil) async throws -> Bottle {
            let bottle = try await store.create(name: name, runtime: RuntimeDescriptor(executableURL: executable(revision), version: "wine-11.0"))
            guard let componentID else { return bottle }
            let metadata = paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString).appendingPathComponent("bottle.json")
            var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            json["graphics"] = ["backend": "dxmt", "componentID": componentID, "showHUD": false]
            try JSONSerialization.data(withJSONObject: json).write(to: metadata)
            return try await store.current(bottle)
        }

        func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        func exists(_ url: URL) -> Bool {
            var status = stat()
            return lstat(url.path, &status) == 0
        }
    }

    private let oldDXVK = "dxvk-macos-1.10.3-magicwine.1"
    private let imported = "d3dmetal-" + String(repeating: "ab", count: 32)

    /// Library with referenced and unreferenced entries of every category.
    private func populate(_ fixture: Fixture) async throws -> (used: [URL], unused: [URL], bottles: [Bottle]) {
        let paths = fixture.paths
        try fixture.runtime(7)
        try fixture.runtime(2)
        try fixture.runtime(3)
        try fixture.runtime(4)
        _ = try fixture.component(DXMTInstallation.componentID)
        _ = try fixture.component(DXVKInstallation.componentID)
        _ = try fixture.component(oldDXVK)
        _ = try fixture.component(imported)
        let current = try await fixture.bottle("Current", revision: 7, componentID: DXMTInstallation.componentID)
        let old = try await fixture.bottle("Old", revision: 3)
        // Pinned to a runtime that no longer exists, with a Metal backend.
        let missing = try await fixture.bottle("Missing", revision: 1, componentID: DXMTInstallation.componentID)
        try await fixture.store.saveSettings(AppSettings(preferredRuntimePath: fixture.executable(4).path))
        let reachable = try fixture.view(7, component: DXMTInstallation.componentID)
        let stale = try fixture.view(2, component: DXMTInstallation.componentID)
        let unreadable = paths.runtimesDirectory.appendingPathComponent(".graphics-views/" + String(repeating: "0", count: 64))
        try fixture.write(Data("partial".utf8), to: unreadable.appendingPathComponent("bin/wine"))
        for bottle in [current, missing] {
            for kind in [GraphicsOperationLease.Kind.launch, .lifetime] {
                try await GraphicsOperationLease.acquire(paths: paths, bottleID: bottle.id, kind: kind, exclusive: true).release()
            }
        }
        let deleted = UUID().uuidString
        let locks = paths.bottlesDirectory.appendingPathComponent(".graphics-locks")
        for name in ["\(deleted)-launch.lock", "\(deleted)-lifetime.lock", "\(deleted).lock"] {
            try fixture.write(Data(), to: locks.appendingPathComponent(name))
        }
        let oldStage = paths.runtimesDirectory.appendingPathComponent(".install-\(UUID().uuidString)")
        try fixture.write(Data("download".utf8), to: oldStage.appendingPathComponent("wine.tar.xz"))
        let past = Date().addingTimeInterval(-2 * StorageCleanup.stagingGracePeriod)
        for url in [oldStage.appendingPathComponent("wine.tar.xz"), oldStage] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        }
        let activeStage = paths.componentsDirectory.appendingPathComponent(".install-dxmt-\(UUID().uuidString)")
        try fixture.write(Data("in progress".utf8), to: activeStage.appendingPathComponent("archive"))
        let unknown = [paths.componentsDirectory.appendingPathComponent("notes.txt"),
                       paths.runtimesDirectory.appendingPathComponent("custom-wine/bin/wine")]
        for url in unknown { try fixture.write(Data("user".utf8), to: url) }
        let used = [paths.runtimesDirectory.appendingPathComponent(fixture.runtimeName(7)),
                    paths.runtimesDirectory.appendingPathComponent(fixture.runtimeName(3)),
                    paths.runtimesDirectory.appendingPathComponent(fixture.runtimeName(4)),
                    paths.componentsDirectory.appendingPathComponent(DXMTInstallation.componentID),
                    paths.componentsDirectory.appendingPathComponent(DXVKInstallation.componentID),
                    reachable, activeStage,
                    locks.appendingPathComponent("\(current.id.uuidString)-launch.lock"),
                    locks.appendingPathComponent("\(current.id.uuidString).lock"),
                    locks.appendingPathComponent("\(missing.id.uuidString)-lifetime.lock")] + unknown +
            [current, old, missing].map { paths.bottlesDirectory.appendingPathComponent($0.id.uuidString) }
        let unused = [paths.runtimesDirectory.appendingPathComponent(fixture.runtimeName(2)),
                      paths.componentsDirectory.appendingPathComponent(oldDXVK),
                      paths.componentsDirectory.appendingPathComponent(imported),
                      stale, unreadable, oldStage] +
            ["\(deleted)-launch.lock", "\(deleted)-lifetime.lock", "\(deleted).lock"].map { locks.appendingPathComponent($0) }
        return (used, unused, [current, old, missing])
    }

    @Test func planListsOnlyUnreferencedEntries() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (used, unused, _) = try await populate(fixture)
        let plan = try await StorageCleanup.plan(paths: fixture.paths)
        #expect(Set(plan.items.map(\.url.standardizedFileURL.path)) == Set(unused.map(\.standardizedFileURL.path)))
        #expect(used.allSatisfy { !plan.items.map(\.url.path).contains($0.path) })
        #expect(plan.keptCurrent.map(\.url.lastPathComponent) == [DXVKInstallation.componentID])
        #expect(plan.items.filter(\.requiresReimport).map(\.url.lastPathComponent) == [imported])
        #expect(plan.items.allSatisfy { !$0.isCurrent && !$0.reason.isEmpty })
        #expect(plan.totalSize == plan.items.reduce(0) { $0 + $1.size })
        #expect(plan.items.first { $0.category == .runtime }!.size > 0)
        let included = try await StorageCleanup.plan(paths: fixture.paths, includeCurrent: true)
        #expect(included.keptCurrent.isEmpty)
        #expect(Set(included.items.map(\.id)) == Set((plan.items + plan.keptCurrent).map(\.id)))
    }

    @Test func applyRemovesConfirmedItemsOnceAndKeepsEverythingElse() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (used, unused, bottles) = try await populate(fixture)
        let plan = try await StorageCleanup.plan(paths: fixture.paths)
        let unconfirmed = try #require(plan.items.first { $0.category == .component })
        let confirmed = plan.items.filter { $0.id != unconfirmed.id }
        let result = try await StorageCleanup.apply(confirmed, paths: fixture.paths)
        #expect(Set(result.removed.map(\.id)) == Set(confirmed.map(\.id)))
        #expect(result.skipped.isEmpty)
        #expect(result.reclaimedSize == confirmed.reduce(0) { $0 + $1.size })
        for url in unused where url.standardizedFileURL.path != unconfirmed.url.standardizedFileURL.path { #expect(!fixture.exists(url)) }
        #expect(fixture.exists(unconfirmed.url))
        for url in used { #expect(fixture.exists(url)) }
        #expect(try await fixture.store.list().map(\.id).sorted { $0.uuidString < $1.uuidString } ==
                bottles.map(\.id).sorted { $0.uuidString < $1.uuidString })
        // Launch still finds the view it would prepare for the remaining bottle.
        _ = try fixture.view(7, component: DXMTInstallation.componentID)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.componentsDirectory.path)
        #expect(!leftovers.contains { $0.hasPrefix(".cleanup-") })

        let again = try await StorageCleanup.apply(confirmed, paths: fixture.paths)
        #expect(again.removed.isEmpty)
        #expect(Set(again.skipped.map(\.id)) == Set(confirmed.map(\.id)))
        #expect(try await StorageCleanup.plan(paths: fixture.paths).items.map(\.id) == [unconfirmed.id])
    }

    @Test(arguments: [GraphicsOperationLease.Kind.launch, .lifetime])
    func applyRefusesWhileAnyBottleHoldsALease(kind: GraphicsOperationLease.Kind) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (_, unused, bottles) = try await populate(fixture)
        let plan = try await StorageCleanup.plan(paths: fixture.paths)
        // Even a bottle pinned to a missing runtime blocks cleanup while it is busy.
        for bottle in [bottles[0], bottles[2]] {
            let lease = try await GraphicsOperationLease.acquire(paths: fixture.paths, bottleID: bottle.id, kind: kind, exclusive: false)
            await #expect(throws: MagicWineError.self) { try await StorageCleanup.apply(plan.items, paths: fixture.paths) }
            lease.release()
        }
        for url in unused { #expect(fixture.exists(url)) }
        // The refused attempt released every lease it took.
        #expect(try await StorageCleanup.apply(plan.items, paths: fixture.paths).removed.count == plan.items.count)
    }

    @Test func applyRefusesWhileAWineServerRuns() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (_, unused, bottles) = try await populate(fixture)
        let marker = fixture.store.prefixURL(for: bottles[1]).appendingPathComponent("external-server")
        try Data().write(to: marker)
        let plan = try await StorageCleanup.plan(paths: fixture.paths)
        await #expect(throws: MagicWineError.self) { try await StorageCleanup.apply(plan.items, paths: fixture.paths) }
        for url in unused { #expect(fixture.exists(url)) }
        try FileManager.default.removeItem(at: marker)
        #expect(try await StorageCleanup.apply(plan.items, paths: fixture.paths).removed.count == plan.items.count)
    }

    @Test func viewsAreKeptWhenALaunchIdentityCannotBeComputed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let ntdll = try fixture.runtime(7).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("lib/wine/x86_64-unix/ntdll.so")
        try fixture.runtime(2)
        _ = try fixture.component(DXMTInstallation.componentID)
        _ = try await fixture.bottle("Current", revision: 7, componentID: DXMTInstallation.componentID)
        let own = try fixture.view(7, component: DXMTInstallation.componentID)
        let other = try fixture.view(2, component: DXMTInstallation.componentID)
        let unreadable = fixture.paths.runtimesDirectory.appendingPathComponent(".graphics-views/" + String(repeating: "0", count: 64))
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        func planned() async throws -> Set<String> {
            Set(try await StorageCleanup.plan(paths: fixture.paths).items.filter { $0.category == .runtimeView }.map(\.url.lastPathComponent))
        }
        // An empty native module makes view planning fail for this bottle's inputs.
        try Data().write(to: ntdll)
        #expect(try await planned() == [other.lastPathComponent])
        // Changed runtime bytes give the bottle a new identity: its old view is stale.
        try Data("updated ntdll".utf8).write(to: ntdll)
        #expect(try await planned() == [own.lastPathComponent, other.lastPathComponent, unreadable.lastPathComponent])
    }

    @Test func retainedComponentAndItsViewStayReachableUntilNoBottleUsesThem() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let retained = "dxmt-v0.80-remote.1"
        #expect(DXMTInstallation.retainedComponentIDs.contains(retained))
        try fixture.runtime(7)
        let oldComponent = try fixture.component(retained)
        _ = try fixture.component(DXMTInstallation.componentID)
        let pinned = try await fixture.bottle("Pinned", revision: 7, componentID: retained)
        _ = try await fixture.bottle("Current", revision: 7, componentID: DXMTInstallation.componentID)
        let oldView = try fixture.view(7, component: retained)
        #expect(oldView != (try fixture.view(7, component: DXMTInstallation.componentID)))
        #expect(try await StorageCleanup.plan(paths: fixture.paths).items.isEmpty)

        // After the bottle moves to the current component, only the old one and its view are unused.
        let metadata = fixture.paths.bottlesDirectory.appendingPathComponent(pinned.id.uuidString).appendingPathComponent("bottle.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        json["graphics"] = ["backend": "dxmt", "componentID": DXMTInstallation.componentID, "showHUD": false]
        try JSONSerialization.data(withJSONObject: json).write(to: metadata)
        let plan = try await StorageCleanup.plan(paths: fixture.paths)
        #expect(Set(plan.items.map(\.url.standardizedFileURL.path)) ==
                Set([oldComponent, oldView].map(\.standardizedFileURL.path)))
        #expect(plan.items.allSatisfy { !$0.isCurrent } && plan.keptCurrent.isEmpty)
    }

    @Test func symbolicLinksNeverRedirectRemoval() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let paths = fixture.paths
        let outsideFile = fixture.outside.appendingPathComponent("user-file")
        // A component-shaped link and a link inside a removable component.
        let linkedComponent = paths.componentsDirectory.appendingPathComponent("dxvk-macos-linked")
        try FileManager.default.createSymbolicLink(at: linkedComponent, withDestinationURL: fixture.outside)
        let old = try fixture.component(oldDXVK)
        try FileManager.default.createSymbolicLink(at: old.appendingPathComponent("escape"), withDestinationURL: fixture.outside)
        let swapped = try fixture.component("dxvk-macos-1.10.3-20230507-repack-acd1520ad105")
        let deleted = UUID().uuidString
        let lock = paths.bottlesDirectory.appendingPathComponent(".graphics-locks/\(deleted).lock")
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outsideFile)
        let plan = try await StorageCleanup.plan(paths: paths)
        #expect(Set(plan.items.map(\.url.lastPathComponent)) == [oldDXVK, swapped.lastPathComponent])
        // Replace a planned directory with a link before applying.
        try FileManager.default.removeItem(at: swapped)
        try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: fixture.outside)
        // A fabricated item for a bottle directory or outside path is never removed.
        let bottle = try await fixture.store.create(name: "Keep", runtime: RuntimeDescriptor(executableURL: fixture.executable(7), version: "wine-11.0"))
        let forged = StorageCleanupItem(category: .runtime, url: paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString),
                                        size: 0, reason: "", requiresReimport: false, isCurrent: false,
                                        parent: ["Bottles"], name: bottle.id.uuidString)
        let result = try await StorageCleanup.apply(plan.items + [forged], paths: paths)
        #expect(result.removed.map(\.url.lastPathComponent) == [oldDXVK])
        #expect(Set(result.skipped.map(\.url.lastPathComponent)) == [swapped.lastPathComponent, bottle.id.uuidString])
        #expect(try Data(contentsOf: outsideFile) == Data("keep".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.outside.path) == ["user-file"])
        for url in [linkedComponent, swapped, lock, paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString)] {
            #expect(fixture.exists(url))
        }
        // Linked managed directories are refused instead of followed.
        let views = paths.runtimesDirectory.appendingPathComponent(".graphics-views")
        try FileManager.default.createSymbolicLink(at: views, withDestinationURL: fixture.outside)
        try fixture.write(Data(), to: fixture.outside.appendingPathComponent(String(repeating: "1", count: 64) + "/installation.json"))
        #expect(try await StorageCleanup.plan(paths: paths).items.isEmpty)
        try FileManager.default.removeItem(at: paths.componentsDirectory)
        try FileManager.default.createSymbolicLink(at: paths.componentsDirectory, withDestinationURL: fixture.outside)
        await #expect(throws: MagicWineError.self) { try await StorageCleanup.plan(paths: paths) }
        #expect(try Data(contentsOf: outsideFile) == Data("keep".utf8))
    }
}
