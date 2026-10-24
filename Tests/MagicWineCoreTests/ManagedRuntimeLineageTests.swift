import Foundation
import Testing
@testable import MagicWineCore

struct ManagedRuntimeLineageTests {
    private struct Fixture {
        let base: URL
        let paths: ApplicationPaths
        let lineage: ManagedRuntimeLineage
        let wine: WineRuntime

        /// `linked` reaches the library through a symbolic link to its real directory.
        init(linked: Bool = false) throws {
            base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let real = base.appendingPathComponent("library", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
            var root = real
            if linked {
                root = base.appendingPathComponent("link", isDirectory: true)
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: real)
            }
            paths = ApplicationPaths(root: root)
            try paths.prepare()
            lineage = ManagedRuntimeLineage(paths: paths)
            wine = WineRuntime(paths: paths, store: BottleStore(paths: paths))
        }

        var realRuntimes: URL { base.appendingPathComponent("library/Runtimes", isDirectory: true) }

        /// Creates the executable so symbolic links to it resolve.
        @discardableResult
        func install(_ name: String, under runtimes: URL? = nil,
                     relative: String = RuntimeInstallation.relativeExecutable) throws -> URL {
            let executable = (runtimes ?? paths.runtimesDirectory).appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: executable)
            return executable
        }

        func facts(_ executable: URL) -> (msync: Bool, metal: Bool, upgrade: Bool) {
            let runtime = RuntimeDescriptor(executableURL: executable, version: "wine-11.0")
            let facts = wine.runtimeFacts(for: executable)
            #expect(facts.managedMSync == wine.supportsMSync(runtime))
            return (facts.managedMSync, facts.managedMetal, wine.canUpgradeRuntime(runtime))
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    @Test func revisionComesFromTheDriverPins() {
        #expect("\(ManagedRuntimeLineage.driverFamily).\(ManagedRuntimeLineage.currentRevision)" == WineMetalBuildPins.componentID)
        #expect(ManagedRuntimeLineage.historicalRevisions == 1..<ManagedRuntimeLineage.currentRevision)
    }

    @Test func currentRevisionAloneHasMSync() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let current = try fixture.install(ManagedRuntimeLineage.currentDirectoryName)
        #expect(current.deletingLastPathComponent().path.hasPrefix(RuntimeInstallation.destination(paths: fixture.paths).path))
        #expect(fixture.lineage.revision(of: current) == ManagedRuntimeLineage.currentRevision)
        #expect(fixture.lineage.isCurrent(current))
        #expect(fixture.lineage.isManagedMetal(current))
        #expect(!fixture.lineage.isUpgradable(current))
        #expect(fixture.facts(current) == (true, true, false))
    }

    @Test func historicalRevisionsAreManagedAndUpgradable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for revision in ManagedRuntimeLineage.historicalRevisions {
            let executable = try fixture.install(ManagedRuntimeLineage.directoryName(revision: revision))
            #expect(fixture.lineage.revision(of: executable) == revision)
            #expect(fixture.lineage.isUpgradable(executable))
            #expect(!fixture.lineage.isCurrent(executable))
            #expect(fixture.facts(executable) == (false, true, true))
        }
    }

    @Test func newerRevisionIsManagedButNeitherCurrentNorUpgradable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let newer = try fixture.install(ManagedRuntimeLineage.directoryName(revision: ManagedRuntimeLineage.currentRevision + 1))
        #expect(fixture.lineage.revision(of: newer) == ManagedRuntimeLineage.currentRevision + 1)
        #expect(fixture.facts(newer) == (false, true, false))
    }

    @Test func unknownLayoutsAndCustomWineAreNotManaged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stem = String(ManagedRuntimeLineage.directoryName(revision: 1).dropLast())
        var unknown = try ["0", "07", "x", "7.bak", "-1", ""].map { try fixture.install(stem + $0) }
        // Another archive, another file of a managed runtime, and the same name outside Runtimes.
        unknown.append(try fixture.install("wine-\(RuntimeInstallation.version)-000000000000-\(ManagedRuntimeLineage.driverFamily).6"))
        unknown.append(try fixture.install(ManagedRuntimeLineage.directoryName(revision: 6),
                                           relative: "Wine Stable.app/Contents/Resources/wine/bin/wine64"))
        unknown.append(try fixture.install(ManagedRuntimeLineage.directoryName(revision: 6),
                                           under: fixture.paths.root.appendingPathComponent("Elsewhere", isDirectory: true)))
        unknown.append(URL(fileURLWithPath: "/opt/homebrew/bin/wine"))
        for executable in unknown {
            #expect(fixture.lineage.revision(of: executable) == nil, "\(executable.path)")
            #expect(fixture.facts(executable) == (false, false, false), "\(executable.path)")
        }
    }

    @Test func symbolicLinksResolveToTheRuntimeTheyReach() throws {
        let fixture = try Fixture(linked: true)
        defer { fixture.remove() }
        let historical = try fixture.install(ManagedRuntimeLineage.directoryName(revision: 6))
        let current = try fixture.install(ManagedRuntimeLineage.currentDirectoryName)
        // The same files through the library link and through its real location.
        for runtimes in [fixture.paths.runtimesDirectory, fixture.realRuntimes] {
            let viaHistorical = runtimes.appendingPathComponent(ManagedRuntimeLineage.directoryName(revision: 6))
                .appendingPathComponent(RuntimeInstallation.relativeExecutable)
            let viaCurrent = runtimes.appendingPathComponent(ManagedRuntimeLineage.currentDirectoryName)
                .appendingPathComponent(RuntimeInstallation.relativeExecutable)
            #expect(fixture.facts(viaHistorical) == (false, true, true))
            #expect(fixture.facts(viaCurrent) == (true, true, false))
        }
        // An alias elsewhere (such as a Homebrew-style link) is the runtime it points to.
        let alias = fixture.base.appendingPathComponent("wine-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: historical)
        #expect(fixture.facts(alias) == (false, true, true))
        try FileManager.default.removeItem(at: alias)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: current)
        #expect(fixture.facts(alias) == (true, true, false))
        // A historical runtime directory that is itself a link to the current one is the current one.
        let linkedRevision = fixture.paths.runtimesDirectory.appendingPathComponent(ManagedRuntimeLineage.directoryName(revision: 5))
        try FileManager.default.createSymbolicLink(at: linkedRevision,
            withDestinationURL: fixture.paths.runtimesDirectory.appendingPathComponent(ManagedRuntimeLineage.currentDirectoryName))
        #expect(fixture.facts(linkedRevision.appendingPathComponent(RuntimeInstallation.relativeExecutable)) == (true, true, false))
    }
}
