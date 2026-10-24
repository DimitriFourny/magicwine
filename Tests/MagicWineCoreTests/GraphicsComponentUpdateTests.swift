import CryptoKit
import Foundation
import Testing
@testable import MagicWineCore

/// In-place component updates with fixture DXVK-footprint components. Each fixture
/// component has its own receipt and independently compiled pins in a temp root.
struct GraphicsComponentUpdateTests {
    private static let oldID = "dxvk-fixture-old"
    private static let newID = "dxvk-fixture-new"
    private static let unknownID = "dxvk-fixture-unknown"
    private static let sources = DXVKComponentProvider().prefixMappings.map(\.source) + ["dxvk.conf"]

    private static func contents(_ id: String, _ source: String) -> Data { Data("\(id) \(source)".utf8) }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func receipt(_ id: String) -> Data { Data("{\"componentID\":\"\(id)\"}".utf8) }

    /// The DXVK prefix footprint and launch facts with fixture components: the new one is
    /// "bundled", the old one retained, anything else unsupported.
    private struct FixtureProvider: GraphicsComponentProvider {
        var backend: GraphicsBackend { .dxvk }
        var componentPrefix: String { "dxvk-" }
        var currentComponentID: String? { GraphicsComponentUpdateTests.newID }
        var retainedComponentIDs: [String] { [GraphicsComponentUpdateTests.oldID] }
        var prefixMappings: [GraphicsPrefixMapping] { DXVKComponentProvider().prefixMappings }
        var cacheFolder: String? { "graphics/cache" }

        func install(paths: ApplicationPaths, source: URL?,
                     progress: (@Sendable (GraphicsSetupProgress) -> Void)?) async throws -> URL {
            let root = paths.componentsDirectory.appendingPathComponent(GraphicsComponentUpdateTests.newID)
            if !FileManager.default.fileExists(atPath: root.path) {
                try GraphicsComponentUpdateTests.writeComponent(GraphicsComponentUpdateTests.newID, paths: paths)
            }
            return try validate(componentID: GraphicsComponentUpdateTests.newID, paths: paths)
        }

        func validate(componentID: String, paths: ApplicationPaths) throws -> URL {
            guard supports(componentID: componentID) else { throw MagicWineError.setup("Unsupported fixture component.") }
            let root = paths.componentsDirectory.appendingPathComponent(componentID)
            guard try Data(contentsOf: root.appendingPathComponent("installation.json")) ==
                    GraphicsComponentUpdateTests.receipt(componentID) else {
                throw MagicWineError.setup("Fixture receipt mismatch.")
            }
            for source in GraphicsComponentUpdateTests.sources {
                let pin = GraphicsComponentUpdateTests.digest(GraphicsComponentUpdateTests.contents(componentID, source))
                guard GraphicsComponentUpdateTests.digest(try Data(contentsOf: root.appendingPathComponent(source))) == pin else {
                    throw MagicWineError.setup("Fixture checksum mismatch: \(source).")
                }
            }
            return root
        }

        func validateRuntime(_ executable: URL) throws {}

        func launchFacts(component: URL, showHUD: Bool, folders: GraphicsFolders?,
                         loader: URL?, server: URL) throws -> GraphicsLaunchFacts {
            guard let folders else { throw MagicWineError.setup("Fixture launch needs graphics folders.") }
            return .dxvk(component: component, folders: folders, showHUD: showHUD)
        }
    }

    @discardableResult
    private static func writeComponent(_ id: String, paths: ApplicationPaths) throws -> URL {
        let root = paths.componentsDirectory.appendingPathComponent(id)
        for source in sources {
            let file = root.appendingPathComponent(source)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents(id, source).write(to: file)
        }
        try receipt(id).write(to: root.appendingPathComponent("installation.json"))
        return root
    }

    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let wine: WineRuntime
        let bottle: Bottle
        let originals: [String: Data]
        var prefix: URL { store.prefixURL(for: bottle) }
        var directory: URL { prefix.deletingLastPathComponent() }
        var metadata: URL { directory.appendingPathComponent("bottle.json") }

        /// A bottle with original DLLs, its graphics set to `componentID` (DXVK footprint).
        init(componentID: String) async throws {
            let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            self.paths = paths
            let executable = paths.root.appendingPathComponent("custom/bin/wine")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            if [ "$1" = -k ]; then touch "$WINEPREFIX/killed"; fi
            case "$1" in *.exe) env > "$WINEPREFIX/launch-environment" ;; esac
            exit 0
            """
            for url in [executable, executable.deletingLastPathComponent().appendingPathComponent("wineserver")] {
                try Data(script.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            store = BottleStore(paths: paths)
            wine = WineRuntime(paths: paths, store: store)
            await wine.useGraphicsProviders(GraphicsComponentProviders([FixtureProvider()]))
            var bottle = try await store.create(name: "Update", runtime: RuntimeDescriptor(executableURL: executable, version: "wine-11.0"))
            let prefix = store.prefixURL(for: bottle)
            for folder in ["system32", "syswow64"] {
                try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/" + folder),
                                                        withIntermediateDirectories: true)
            }
            var originals: [String: Data] = [:]
            for path in GraphicsPrefix.dllPaths {
                originals[path] = Data("original \(path)".utf8)
                try originals[path]!.write(to: prefix.appendingPathComponent(path))
            }
            self.originals = originals
            bottle = try await store.markInitialized(bottle)
            let component = try GraphicsComponentUpdateTests.writeComponent(componentID, paths: paths)
            self.bottle = try await store.setGraphics(GraphicsConfiguration(backend: .dxvk, componentID: componentID, showHUD: true),
                                                      in: bottle, componentRoot: component)
        }

        func installed(_ path: String) throws -> Data { try Data(contentsOf: prefix.appendingPathComponent(path)) }

        func expectFootprint(of id: String) throws {
            for mapping in DXVKComponentProvider().prefixMappings {
                #expect(try installed(mapping.destination) == GraphicsComponentUpdateTests.contents(id, mapping.source))
            }
        }

        func launchedComponent() async throws -> String? {
            let program = prefix.appendingPathComponent("drive_c/game.exe")
            try Data("MZ".utf8).write(to: program)
            _ = try await wine.launch(WindowsProgram(name: "Game", executablePath: program.path), in: bottle)
            let text = try String(contentsOf: prefix.appendingPathComponent("launch-environment"), encoding: .utf8)
            let line = text.split(separator: "\n").first { $0.hasPrefix("DXVK_CONFIG_FILE=") }
            return line.map { URL(fileURLWithPath: String($0.dropFirst("DXVK_CONFIG_FILE=".count))).deletingLastPathComponent().lastPathComponent }
        }

        func nextMetadata(_ configuration: GraphicsConfiguration) throws -> Data {
            var next = try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: metadata))
            next.graphics = configuration
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(next)
        }

        func restoreStandardAndExpectOriginals() async throws {
            _ = try await store.setGraphics(.init(), in: bottle, componentRoot: nil)
            for (path, data) in originals { #expect(try installed(path) == data) }
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    @Test func retainedOlderComponentKeepsLaunchingWithItsOwnPins() async throws {
        let fixture = try await Fixture(componentID: Self.oldID)
        defer { fixture.remove() }
        #expect(try await fixture.launchedComponent() == Self.oldID)

        let conf = fixture.paths.componentsDirectory.appendingPathComponent("\(Self.oldID)/dxvk.conf")
        try Data("changed".utf8).write(to: conf)
        await #expect(throws: MagicWineError.self) { _ = try await fixture.launchedComponent() }
    }

    @Test func updateSwitchesPrefixFilesAndMetadataTogetherAndKeepsTheOldComponent() async throws {
        let fixture = try await Fixture(componentID: Self.oldID)
        defer { fixture.remove() }
        let custom = Data("user replacement of an old component DLL".utf8)
        let customPath = GraphicsPrefix.dllPaths[1]
        try custom.write(to: fixture.prefix.appendingPathComponent(customPath), options: .atomic)

        await #expect(throws: MagicWineError.self) {
            _ = try await fixture.wine.updateGraphicsComponent(in: fixture.bottle)
        }
        #expect(try await fixture.store.current(fixture.bottle).graphics.componentID == Self.oldID)

        let updated = try await fixture.wine.updateGraphicsComponent(in: fixture.bottle, acceptExperimental: true)
        #expect(updated.graphics == GraphicsConfiguration(backend: .dxvk, componentID: Self.newID, showHUD: true))
        #expect(try await fixture.store.current(fixture.bottle).graphics == updated.graphics)
        #expect(FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent("killed").path))
        try fixture.expectFootprint(of: Self.newID)
        try GraphicsPrefix.validateInstalled(configuration: updated.graphics, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/transaction").path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.componentsDirectory.appendingPathComponent(Self.oldID).path))
        let recovered = fixture.directory.appendingPathComponent("graphics/recovered")
        let preserved = try #require(FileManager.default.enumerator(at: recovered, includingPropertiesForKeys: nil))
            .allObjects.compactMap { $0 as? URL }.filter { (try? Data(contentsOf: $0)) == custom }
        #expect(preserved.count == 1)
        #expect(try await fixture.launchedComponent() == Self.newID)

        // Already current: nothing to do.
        let metadata = try Data(contentsOf: fixture.metadata)
        #expect(try await fixture.wine.updateGraphicsComponent(in: updated, acceptExperimental: true).graphics == updated.graphics)
        #expect(try Data(contentsOf: fixture.metadata) == metadata)

        try await fixture.restoreStandardAndExpectOriginals()
    }

    @Test(arguments: [false, true])
    func interruptedUpdateRecoversThroughTheJournal(committed: Bool) async throws {
        let fixture = try await Fixture(componentID: Self.oldID)
        defer { fixture.remove() }
        let previous = fixture.bottle.graphics
        var next = previous
        next.componentID = Self.newID
        let component = try Self.writeComponent(Self.newID, paths: fixture.paths)
        let previousData = try Data(contentsOf: fixture.metadata)
        let nextData = try fixture.nextMetadata(next)
        try GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: previous, to: next, componentRoot: component,
                                                         bottleDirectory: fixture.directory, previousMetadata: previousData,
                                                         nextMetadata: nextData, componentUpdate: true)
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
            // The process dies here: before or right after the metadata commit.
            if committed { try nextData.write(to: fixture.metadata, options: .atomic) }
        }
        try fixture.expectFootprint(of: Self.newID)

        let recovered = try await fixture.store.current(fixture.bottle)
        #expect(recovered.graphics == (committed ? next : previous))
        try fixture.expectFootprint(of: committed ? Self.newID : Self.oldID)
        try GraphicsPrefix.validateInstalled(configuration: recovered.graphics, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/transaction").path))
        try await fixture.restoreStandardAndExpectOriginals()
    }

    @Test func unknownComponentStillRequiresRestoringStandard() async throws {
        let fixture = try await Fixture(componentID: Self.unknownID)
        defer { fixture.remove() }
        let metadata = try Data(contentsOf: fixture.metadata)

        await #expect(throws: MagicWineError.self) {
            _ = try await fixture.wine.updateGraphicsComponent(in: fixture.bottle, acceptExperimental: true)
        }
        await #expect(throws: MagicWineError.self) {
            _ = try await fixture.wine.configureGraphics(.dxvk, in: fixture.bottle, acceptExperimental: true)
        }
        await #expect(throws: MagicWineError.self) { _ = try await fixture.launchedComponent() }
        #expect(try Data(contentsOf: fixture.metadata) == metadata)
        try fixture.expectFootprint(of: Self.unknownID)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.componentsDirectory.appendingPathComponent(Self.newID).path))

        // A plain selection change still refuses a different component of the same backend.
        let component = try Self.writeComponent(Self.newID, paths: fixture.paths)
        await #expect(throws: MagicWineError.self) {
            _ = try await fixture.store.setGraphics(.init(backend: .dxvk, componentID: Self.newID), in: fixture.bottle,
                                                    componentRoot: component)
        }
        try fixture.expectFootprint(of: Self.unknownID)
        try await fixture.restoreStandardAndExpectOriginals()
    }

    @Test func bundledProvidersOfferUpdatesOnlyFromRetainedComponents() {
        let historicalDXMT = GraphicsConfiguration(backend: .dxmt, componentID: "dxmt-v0.80")
        #expect(historicalDXMT.usesSupportedComponent && historicalDXMT.hasComponentUpdate)
        let currentDXMT = GraphicsConfiguration(backend: .dxmt, componentID: DXMTInstallation.componentID)
        #expect(currentDXMT.usesSupportedComponent && !currentDXMT.hasComponentUpdate)
        let currentDXVK = GraphicsConfiguration(backend: .dxvk, componentID: DXVKInstallation.componentID)
        #expect(currentDXVK.usesSupportedComponent && !currentDXVK.hasComponentUpdate)
        let oldDXVK = GraphicsConfiguration(backend: .dxvk, componentID: "dxvk-macos-1.10.3-magicwine.1")
        #expect(!oldDXVK.usesSupportedComponent && !oldDXVK.hasComponentUpdate)
        let imported = GraphicsConfiguration(backend: .d3dmetal, componentID: "d3dmetal-" + String(repeating: "a", count: 64))
        #expect(imported.usesSupportedComponent && !imported.hasComponentUpdate)
        #expect(!GraphicsConfiguration().hasComponentUpdate)
    }
}
