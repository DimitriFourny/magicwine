import Foundation
import Testing
@testable import MagicWineCore

struct GraphicsPersistenceTests {
    private let runtime = RuntimeDescriptor(executableURL: URL(fileURLWithPath: "/opt/wine/bin/wine"), version: "wine-11")
    private let selection = GraphicsConfiguration(backend: .dxvk, componentID: "test-native-component")
    private let sources = ["x64/d3d10core.dll", "x64/d3d11.dll", "x32/d3d10core.dll", "x32/d3d11.dll"]

    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let bottle: Bottle
        let component: URL
        let directory: URL
        let prefix: URL
        var metadata: URL { directory.appendingPathComponent("bottle.json") }
        func dll(_ index: Int) -> URL { prefix.appendingPathComponent(GraphicsPrefix.dllPaths[index]) }
    }

    private func fixture(initialized: Bool = true) async throws -> Fixture {
        let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let store = BottleStore(paths: paths)
        var bottle = try await store.create(name: "Graphics", runtime: runtime)
        let prefix = store.prefixURL(for: bottle)
        if initialized {
            for directory in ["drive_c/windows/system32", "drive_c/windows/syswow64"] {
                try FileManager.default.createDirectory(at: prefix.appendingPathComponent(directory), withIntermediateDirectories: true)
            }
            bottle.isInitialized = true
            try await store.save(bottle)
        }
        let component = paths.componentsDirectory.appendingPathComponent("test-native-component")
        for architecture in ["x32", "x64"] {
            try FileManager.default.createDirectory(at: component.appendingPathComponent(architecture), withIntermediateDirectories: true)
        }
        for (index, source) in sources.enumerated() {
            try Data("native DLL \(index)".utf8).write(to: component.appendingPathComponent(source))
        }
        return Fixture(paths: paths, store: store, bottle: bottle, component: component,
                       directory: prefix.deletingLastPathComponent(), prefix: prefix)
    }

    private func writeOriginals(_ fixture: Fixture) throws -> [Data] {
        let originals = (0..<4).map { Data("original DLL \($0)".utf8) }
        for index in originals.indices { try originals[index].write(to: fixture.dll(index)) }
        return originals
    }

    private func nextMetadata(_ fixture: Fixture, configuration: GraphicsConfiguration) throws -> Data {
        var next = try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: fixture.metadata))
        next.graphics = configuration
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(next)
    }

    @Test func historicalMetadataReadsWithoutRewriteAndRetainsRequiredFields() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata)) as? [String: Any])
        json.removeValue(forKey: "graphics")
        json["createdAt"] = 123456.125
        let historical = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        try historical.write(to: fixture.metadata)
        let current = try await fixture.store.current(fixture.bottle)
        let listed = try await BottleStore(paths: fixture.paths).list()
        #expect(current.graphics == GraphicsConfiguration())
        #expect(current.createdAt == Date(timeIntervalSinceReferenceDate: 123456.125))
        #expect(listed == [current])
        #expect(try Data(contentsOf: fixture.metadata) == historical)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics").path))
        for required in ["id", "name", "createdAt", "runtime", "isInitialized", "programs"] {
            var malformed = json
            malformed.removeValue(forKey: required)
            let data = try JSONSerialization.data(withJSONObject: malformed)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(Bottle.self, from: data) }
        }
        json["graphics"] = ["backend": "unknown", "showHUD": false]
        let unknown = try JSONSerialization.data(withJSONObject: json)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Bottle.self, from: unknown) }
    }

    @Test func staleRendererSelectionPreservesProgramsMetadataAndOtherBottles() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let other = try await fixture.store.create(name: "Other", runtime: runtime)
        let otherDirectory = fixture.store.prefixURL(for: other).deletingLastPathComponent()
        let otherMetadata = try Data(contentsOf: otherDirectory.appendingPathComponent("bottle.json"))
        let untouched = fixture.prefix.appendingPathComponent("drive_c/windows/system32/dxgi.dll")
        let d3d9 = fixture.prefix.appendingPathComponent("drive_c/windows/syswow64/d3d9.dll")
        try Data("custom DXGI".utf8).write(to: untouched)
        try Data("custom D3D9".utf8).write(to: d3d9)
        let exe = fixture.paths.root.appendingPathComponent("Game.exe")
        try Data([0x4d, 0x5a]).write(to: exe)
        var saved = try await fixture.store.registerProgram(in: fixture.bottle, executableURL: exe)
        saved.name = "Renamed after snapshot"
        try await fixture.store.save(saved)
        let selected = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        #expect(selected.programs == saved.programs)
        #expect(selected.name == saved.name)
        #expect(selected.createdAt == saved.createdAt)
        #expect(selected.runtime == saved.runtime)
        for index in originals.indices {
            #expect(try Data(contentsOf: fixture.dll(index)) == Data(contentsOf: fixture.component.appendingPathComponent(sources[index])))
        }
        #expect(try Data(contentsOf: untouched) == Data("custom DXGI".utf8))
        #expect(try Data(contentsOf: d3d9) == Data("custom D3D9".utf8))
        #expect(try Data(contentsOf: otherDirectory.appendingPathComponent("bottle.json")) == otherMetadata)
        #expect(!FileManager.default.fileExists(atPath: otherDirectory.appendingPathComponent("graphics").path))
        let restored = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        #expect(restored.programs == saved.programs)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
    }

    @Test func repeatAndHUDOnlyChangesRetainOriginalLinksAbsenceAndCustomReplacements() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let external = fixture.paths.root.appendingPathComponent("outside-original.dll")
        let externalData = Data("outside target must not change".utf8)
        try externalData.write(to: external)
        let first = Data("first original".utf8)
        let fourth = Data("fourth original".utf8)
        try first.write(to: fixture.dll(0))
        try FileManager.default.createSymbolicLink(atPath: fixture.dll(1).path, withDestinationPath: external.path)
        // DLL 2 is originally absent.
        try fourth.write(to: fixture.dll(3))
        _ = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        let managed = try Data(contentsOf: fixture.dll(0))
        let custom = Data("user-installed replacement".utf8)
        try custom.write(to: fixture.dll(0), options: .atomic)
        try FileManager.default.removeItem(at: fixture.dll(3))
        try FileManager.default.createSymbolicLink(atPath: fixture.dll(3).path, withDestinationPath: "missing-user-target.dll")
        try FileManager.default.removeItem(at: fixture.component)
        var hud = selection
        hud.showHUD = true
        _ = try await fixture.store.setGraphics(hud, in: fixture.bottle, componentRoot: nil)
        _ = try await fixture.store.setGraphics(hud, in: fixture.bottle, componentRoot: nil)
        #expect(try Data(contentsOf: fixture.dll(0)) == custom)
        #expect(custom != managed)
        let standard = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        #expect(standard.graphics.backend == .standard)
        #expect(try Data(contentsOf: fixture.dll(0)) == first)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.dll(1).path) == external.path)
        #expect(!FileManager.default.fileExists(atPath: fixture.dll(2).path))
        #expect(try Data(contentsOf: fixture.dll(3)) == fourth)
        #expect(try Data(contentsOf: external) == externalData)
        let recovery = fixture.directory.appendingPathComponent("graphics/recovered")
        let enumerator = try #require(FileManager.default.enumerator(at: recovery, includingPropertiesForKeys: nil))
        var savedCustom = false
        var savedLink = false
        for case let file as URL in enumerator.allObjects {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                savedLink = savedLink || target == "missing-user-target.dll"
            } else if attributes[.type] as? FileAttributeType == .typeRegular {
                let data = try Data(contentsOf: file)
                savedCustom = savedCustom || data == custom
            }
        }
        #expect(savedCustom)
        #expect(savedLink)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/active").path))
    }

    @Test func componentReplacementIsRejectedWithoutChangingBottleOrBackups() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let selected = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        let custom = Data("user replacement must survive a rejected component change".utf8)
        try custom.write(to: fixture.dll(0), options: .atomic)
        let replacement = fixture.paths.componentsDirectory.appendingPathComponent("replacement-native-component")
        try FileManager.default.copyItem(at: fixture.component, to: replacement)
        let metadata = try Data(contentsOf: fixture.metadata)
        let manifest = fixture.directory.appendingPathComponent("graphics/active/manifest.json")
        let backupManifest = try Data(contentsOf: manifest)
        let installed = try sources.indices.map { try Data(contentsOf: fixture.dll($0)) }
        let configuration = GraphicsConfiguration(backend: .dxvk, componentID: replacement.lastPathComponent)

        await #expect(throws: MagicWineError.self) {
            try await fixture.store.setGraphics(configuration, in: selected, componentRoot: replacement)
        }
        #expect(try await fixture.store.current(fixture.bottle).graphics == selection)
        #expect(try Data(contentsOf: fixture.metadata) == metadata)
        #expect(try Data(contentsOf: manifest) == backupManifest)
        for index in installed.indices { #expect(try Data(contentsOf: fixture.dll(index)) == installed[index]) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/transaction").path))

        _ = try await fixture.store.setGraphics(.init(), in: selected, componentRoot: nil)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        let recovery = fixture.directory.appendingPathComponent("graphics/recovered")
        let enumerator = try #require(FileManager.default.enumerator(at: recovery, includingPropertiesForKeys: nil))
        #expect(try enumerator.allObjects.compactMap { $0 as? URL }.contains {
            guard $0.lastPathComponent == "x64-d3d10core.dll" else { return false }
            return try Data(contentsOf: $0) == custom
        })
    }

    @Test func onlyInitializedOwnedPrefixesWithOrdinaryDestinationDirectoriesCanChange() async throws {
        let uninitialized = try await fixture(initialized: false)
        defer { try? FileManager.default.removeItem(at: uninitialized.paths.root) }
        let old = try Data(contentsOf: uninitialized.metadata)
        await #expect(throws: MagicWineError.self) {
            try await uninitialized.store.setGraphics(selection, in: uninitialized.bottle, componentRoot: uninitialized.component)
        }
        #expect(try Data(contentsOf: uninitialized.metadata) == old)
        #expect(!FileManager.default.fileExists(atPath: uninitialized.directory.appendingPathComponent("graphics").path))
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let outside = fixture.paths.root.appendingPathComponent("outside")
        let syswow64 = fixture.prefix.appendingPathComponent("drive_c/windows/syswow64")
        try FileManager.default.moveItem(at: syswow64, to: outside)
        try FileManager.default.createSymbolicLink(at: syswow64, withDestinationURL: outside)
        await #expect(throws: MagicWineError.self) {
            try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        }
        #expect(try Data(contentsOf: fixture.dll(0)) == originals[0])
        #expect(try Data(contentsOf: outside.appendingPathComponent("d3d10core.dll")) == originals[2])
        #expect(try await fixture.store.current(fixture.bottle).graphics.backend == .standard)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics").path))
        let foreign = Bottle(name: "Foreign", runtime: runtime, isInitialized: true)
        try JSONEncoder().encode(foreign).write(to: fixture.metadata)
        await #expect(throws: MagicWineError.self) {
            try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        }
        #expect(try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: fixture.metadata)) == foreign)
    }

    @Test func missingComponentDLLFailsBeforeAnyPrefixChanges() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let old = try Data(contentsOf: fixture.metadata)
        try FileManager.default.removeItem(at: fixture.component.appendingPathComponent(sources[3]))
        await #expect(throws: (any Error).self) {
            try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        }
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        #expect(try Data(contentsOf: fixture.metadata) == old)
    }

    @Test func metadataWriteFailureRollsBackInstallationAndRestoration() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let old = try Data(contentsOf: fixture.metadata)
        let next = try nextMetadata(fixture, configuration: selection)
        #expect(throws: (any Error).self) {
            try GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
                try GraphicsPrefix.change(from: .init(), to: selection, componentRoot: fixture.component,
                                          bottleDirectory: fixture.directory, previousMetadata: old, nextMetadata: next) {
                    // An actual atomic-write failure, not a mocked successful metadata commit.
                    try next.write(to: fixture.paths.root, options: .atomic)
                }
            }
        }
        #expect(try Data(contentsOf: fixture.metadata) == old)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        let installed = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        let installedMetadata = try Data(contentsOf: fixture.metadata)
        let standardMetadata = try nextMetadata(fixture, configuration: .init())
        let managed = try (0..<4).map { try Data(contentsOf: fixture.dll($0)) }
        #expect(throws: (any Error).self) {
            try GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
                try GraphicsPrefix.change(from: selection, to: .init(), componentRoot: nil,
                                          bottleDirectory: fixture.directory, previousMetadata: installedMetadata,
                                          nextMetadata: standardMetadata) {
                    try standardMetadata.write(to: fixture.paths.root, options: .atomic)
                }
            }
        }
        #expect(try await fixture.store.current(fixture.bottle) == installed)
        for index in managed.indices { #expect(try Data(contentsOf: fixture.dll(index)) == managed[index]) }
        try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
    }

    @Test func partialFileFailureIsRecoveredByFreshReadsBeforeItCanLaunch() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let old = try Data(contentsOf: fixture.metadata)
        let next = try nextMetadata(fixture, configuration: selection)
        try GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: old, nextMetadata: next)
            try FileManager.default.removeItem(at: transaction.appendingPathComponent("after/2"))
            #expect(throws: (any Error).self) { try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory) }
            #expect(try Data(contentsOf: fixture.dll(0)) != originals[0])
        }
        let current = try await BottleStore(paths: fixture.paths).current(fixture.bottle)
        #expect(current.graphics.backend == .standard)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        #expect(try Data(contentsOf: fixture.metadata) == old)
    }

    @Test func interruptedBeforeCommitRollsBackAndAfterCommitKeepsSelectedRenderer() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let old = try Data(contentsOf: fixture.metadata)
        let next = try nextMetadata(fixture, configuration: selection)
        try GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: old, nextMetadata: next)
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
            // Simulate a killed process: no metadata commit and no transaction cleanup.
        }
        let rollback = try await BottleStore(paths: fixture.paths).list()
        #expect(rollback.first?.graphics.backend == .standard)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        try GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: old, nextMetadata: next)
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
            try next.write(to: fixture.metadata, options: .atomic)
            // Simulate a kill after the atomic commit but before cleanup.
        }
        let committed = try await BottleStore(paths: fixture.paths).list()
        #expect(committed.first?.graphics == selection)
        try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        let selectedMetadata = try Data(contentsOf: fixture.metadata)
        let standard = try nextMetadata(fixture, configuration: .init())
        try GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: selection, to: .init(), componentRoot: nil,
                                                         bottleDirectory: fixture.directory, previousMetadata: selectedMetadata,
                                                         nextMetadata: standard)
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
            // An interrupted switchback must keep the preceding DXVK selection usable.
        }
        let recovered = try await BottleStore(paths: fixture.paths).current(fixture.bottle)
        #expect(recovered.graphics == selection)
        try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
    }

    @Test func concurrentStoresPreserveProgramsAndRendererTransactions() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let executables = (0..<12).map { fixture.paths.root.appendingPathComponent("Game-\($0).exe") }
        for executable in executables { try Data([0x4d, 0x5a]).write(to: executable) }
        let paths = fixture.paths
        let snapshot = fixture.bottle
        let component = fixture.component
        let configuration = selection
        try await withThrowingTaskGroup(of: Void.self) { group in
            for executable in executables {
                group.addTask {
                    let store = BottleStore(paths: paths)
                    _ = try await store.registerProgram(in: snapshot, executableURL: executable)
                }
            }
            group.addTask {
                let store = BottleStore(paths: paths)
                _ = try await store.setGraphics(configuration, in: snapshot, componentRoot: component)
                var hud = configuration
                hud.showHUD = true
                _ = try await store.setGraphics(hud, in: snapshot, componentRoot: nil)
            }
            try await group.waitForAll()
        }
        let current = try await fixture.store.current(snapshot)
        #expect(Set(current.programs.map(\.executablePath)) == Set(executables.map(\.path)))
        #expect(current.graphics.backend == .dxvk)
        #expect(current.graphics.showHUD)
        try GraphicsPrefix.validateInstalled(configuration: current.graphics, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        let restored = try await fixture.store.setGraphics(.init(), in: snapshot, componentRoot: nil)
        #expect(restored.programs == current.programs)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
    }

    @Test func interruptedRecoveryPreservesUserEditsMadeAfterTheCrash() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let previous = try Data(contentsOf: fixture.metadata)
        let next = try nextMetadata(fixture, configuration: selection)
        try GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: previous,
                                                         nextMetadata: next)
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
        }
        let userEdit = Data("DLL replaced by the user after an interrupted install".utf8)
        try userEdit.write(to: fixture.dll(0), options: .atomic)
        let current = try await BottleStore(paths: fixture.paths).current(fixture.bottle)
        #expect(current.graphics.backend == .standard)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        let recovery = fixture.directory.appendingPathComponent("graphics/recovered")
        let files = try #require(FileManager.default.enumerator(at: recovery, includingPropertiesForKeys: [.isRegularFileKey]))
        var retained = false
        for case let file as URL in files.allObjects {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let data = try Data(contentsOf: file)
                retained = retained || data == userEdit
            }
        }
        #expect(retained)
        #expect(try Data(contentsOf: fixture.metadata) == previous)
    }

    @Test func staleWholeBottleSaveCannotDiscardManagedRendererOrBackups() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let selected = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        await #expect(throws: MagicWineError.self) { try await fixture.store.save(fixture.bottle) }
        #expect(try await fixture.store.current(fixture.bottle) == selected)
        try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
    }
}
