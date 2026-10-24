import CryptoKit
import Foundation
import Testing
@testable import MagicWineCore

struct GraphicsPersistenceTests {
    private let runtime = RuntimeDescriptor(executableURL: URL(fileURLWithPath: "/opt/wine/bin/wine"), version: "wine-11")
    private let selection = GraphicsConfiguration(backend: .dxvk, componentID: "test-native-component")
    private let sources = [
        "x64/d3d10core.dll", "x64/d3d11.dll", "x32/d3d10core.dll", "x32/d3d11.dll",
        "x64/d3d9.dll", "x32/d3d9.dll"
    ]

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
            bottle = try await store.markInitialized(bottle)
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
        let originals = sources.indices.map { Data("original DLL \($0)".utf8) }
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

    private func installHistoricalFourDLLs(_ fixture: Fixture) throws -> [Data] {
        let originals = try writeOriginals(fixture)
        let active = fixture.directory.appendingPathComponent("graphics/active")
        let saved = active.appendingPathComponent("originals")
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for index in 0..<4 {
            try originals[index].write(to: saved.appendingPathComponent(String(index)))
            let native = try Data(contentsOf: fixture.component.appendingPathComponent(sources[index]))
            try native.write(to: fixture.dll(index), options: .atomic)
            entries.append([
                "originalExists": true,
                "installedHash": SHA256.hash(data: native).map { String(format: "%02x", $0) }.joined(),
                "installedSize": native.count
            ])
        }
        let manifest: [String: Any] = ["componentID": selection.componentID!, "entries": entries]
        try JSONSerialization.data(withJSONObject: manifest).write(to: active.appendingPathComponent("manifest.json"))
        try nextMetadata(fixture, configuration: selection).write(to: fixture.metadata, options: .atomic)
        return originals
    }

    @Test func legacyFourDLLRestorationAndRecoveryNeverCaptureD3D9OrLoseOriginals() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try installHistoricalFourDLLs(fixture)
        let manifest = fixture.directory.appendingPathComponent("graphics/active/manifest.json")
        let savedManifest = try Data(contentsOf: manifest)
        let selectedMetadata = try Data(contentsOf: fixture.metadata)
        let standardMetadata = try nextMetadata(fixture, configuration: .init())
        let managed = try (0..<4).map { try Data(contentsOf: fixture.dll($0)) }
        let d3d9 = Data("D3D9 installed independently of the historical component".utf8)
        try d3d9.write(to: fixture.dll(4), options: .atomic)
        try FileManager.default.removeItem(at: fixture.dll(5))
        try FileManager.default.createSymbolicLink(atPath: fixture.dll(5).path, withDestinationPath: "outside-d3d9.dll")

        #expect(throws: MagicWineError.self) {
            try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        }
        await #expect(throws: (any Error).self) {
            try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
                try GraphicsPrefix.change(from: selection, to: .init(), componentRoot: nil,
                                          bottleDirectory: fixture.directory, previousMetadata: selectedMetadata,
                                          nextMetadata: standardMetadata) {
                    try standardMetadata.write(to: fixture.paths.root, options: .atomic)
                }
            }
        }
        #expect(try Data(contentsOf: manifest) == savedManifest)
        #expect(try Data(contentsOf: fixture.metadata) == selectedMetadata)
        for index in managed.indices {
            #expect(try Data(contentsOf: fixture.dll(index)) == managed[index])
            #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("graphics/active/originals/\(index)")) == originals[index])
        }
        #expect(try Data(contentsOf: fixture.dll(4)) == d3d9)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.dll(5).path) == "outside-d3d9.dll")

        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: selection, to: .init(), componentRoot: nil,
                                                         bottleDirectory: fixture.directory, previousMetadata: selectedMetadata,
                                                         nextMetadata: standardMetadata)
            let journal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: transaction.appendingPathComponent("journal.json"))) as? [String: Any])
            for key in ["before", "after", "displaced"] {
                #expect((journal[key] as? [Any])?.count == 4)
            }
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
            for index in 0..<4 { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        }
        let afterCrash = Data("D3D9 changed after the interrupted historical rollback".utf8)
        try afterCrash.write(to: fixture.dll(4), options: .atomic)
        let recovered = try await BottleStore(paths: fixture.paths).current(fixture.bottle)
        #expect(recovered.graphics == selection)
        #expect(try Data(contentsOf: manifest) == savedManifest)
        for index in managed.indices {
            #expect(try Data(contentsOf: fixture.dll(index)) == managed[index])
            #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("graphics/active/originals/\(index)")) == originals[index])
        }
        #expect(try Data(contentsOf: fixture.dll(4)) == afterCrash)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.dll(5).path) == "outside-d3d9.dll")
        let restored = try await fixture.store.setGraphics(.init(), in: recovered, componentRoot: nil)
        #expect(restored.graphics.backend == .standard)
        for index in 0..<4 { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        #expect(try Data(contentsOf: fixture.dll(4)) == afterCrash)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.dll(5).path) == "outside-d3d9.dll")
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/active").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/recovered").path))
    }

    @Test(arguments: [false, true])
    func historicalFourDLLInstallJournalRecoversWithoutTouchingD3D9(committed: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let previous = try Data(contentsOf: fixture.metadata)
        let next = try nextMetadata(fixture, configuration: selection)
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: previous, nextMetadata: next)
            // Reproduce the persisted four-entry format, including the historical active backup.
            for (path, keys) in [("journal.json", ["before", "after", "displaced"]),
                                 ("after-active/manifest.json", ["entries"])] {
                let url = transaction.appendingPathComponent(path)
                var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                for key in keys { json[key] = Array(try #require(json[key] as? [Any]).prefix(4)) }
                for key in ["schema", "backend", "paths", "previousPaths", "nextPaths"] {
                    json.removeValue(forKey: key)
                }
                try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
            }
            for index in 4..<6 {
                for path in ["before", "after", "after-active/originals"] {
                    try FileManager.default.removeItem(at: transaction.appendingPathComponent("\(path)/\(index)"))
                }
            }
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
            if committed { try next.write(to: fixture.metadata, options: .atomic) }
        }
        let independentD3D9 = Data("D3D9 changed outside the historical transaction".utf8)
        for index in 4..<6 { try independentD3D9.write(to: fixture.dll(index), options: .atomic) }
        let recovered = try await BottleStore(paths: fixture.paths).current(fixture.bottle)
        #expect(recovered.graphics == (committed ? selection : GraphicsConfiguration()))
        for index in 0..<4 {
            let expected = try (committed ? Data(contentsOf: fixture.component.appendingPathComponent(sources[index])) : originals[index])
            #expect(try Data(contentsOf: fixture.dll(index)) == expected)
        }
        for index in 4..<6 { #expect(try Data(contentsOf: fixture.dll(index)) == independentD3D9) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/transaction").path))
        if committed {
            #expect(throws: MagicWineError.self) {
                try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
            }
            _ = try await fixture.store.setGraphics(.init(), in: recovered, componentRoot: nil)
            for index in 0..<4 { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
            for index in 4..<6 { #expect(try Data(contentsOf: fixture.dll(index)) == independentD3D9) }
        }
    }

    @Test(arguments: [0, 1, 3, 5, 7])
    func invalidManifestCountsCannotRestoreOrLaunch(count: Int) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        _ = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        let manifest = fixture.directory.appendingPathComponent("graphics/active/manifest.json")
        let validManifest = try Data(contentsOf: manifest)
        let metadata = try Data(contentsOf: fixture.metadata)
        let installed = try sources.indices.map { try Data(contentsOf: fixture.dll($0)) }
        var json = try #require(JSONSerialization.jsonObject(with: validManifest) as? [String: Any])
        let entries = try #require(json["entries"] as? [Any])
        json["entries"] = Array(repeating: entries[0], count: count)
        let invalidManifest = try JSONSerialization.data(withJSONObject: json)
        try invalidManifest.write(to: manifest, options: .atomic)
        #expect(throws: MagicWineError.self) {
            try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        }
        await #expect(throws: MagicWineError.self) {
            try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        }
        #expect(try Data(contentsOf: manifest) == invalidManifest)
        #expect(try Data(contentsOf: fixture.metadata) == metadata)
        for index in installed.indices { #expect(try Data(contentsOf: fixture.dll(index)) == installed[index]) }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/transaction").path))
        try validManifest.write(to: manifest, options: .atomic)
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
    }

    @Test(arguments: [[0, 0, 0], [3, 3, 3], [5, 5, 5], [7, 7, 7], [4, 6, 4], [6, 6, 4]])
    func invalidJournalCountsRetainRecoveryFilesWithoutChangingDLLs(counts: [Int]) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let previous = try Data(contentsOf: fixture.metadata)
        let next = try nextMetadata(fixture, configuration: selection)
        let journalURL = fixture.directory.appendingPathComponent("graphics/transaction/journal.json")
        let validJournal = try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: previous, nextMetadata: next)
            let data = try Data(contentsOf: journalURL)
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            for (index, key) in ["before", "after", "displaced"].enumerated() {
                let entries = try #require(json[key] as? [Any])
                json[key] = Array(repeating: entries[0], count: counts[index])
            }
            try JSONSerialization.data(withJSONObject: json).write(to: journalURL, options: .atomic)
            #expect(throws: MagicWineError.self) {
                try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
            }
            return data
        }
        let invalidJournal = try Data(contentsOf: journalURL)
        await #expect(throws: MagicWineError.self) { try await fixture.store.current(fixture.bottle) }
        #expect(try Data(contentsOf: journalURL) == invalidJournal)
        #expect(try Data(contentsOf: fixture.metadata) == previous)
        for index in originals.indices {
            #expect(try Data(contentsOf: fixture.dll(index)) == originals[index])
            #expect(try Data(contentsOf: fixture.directory.appendingPathComponent("graphics/transaction/before/\(index)")) == originals[index])
        }
        try validJournal.write(to: journalURL, options: .atomic)
        let recovered = try await fixture.store.current(fixture.bottle)
        #expect(recovered.graphics.backend == .standard)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        #expect(!FileManager.default.fileExists(atPath: journalURL.path))
    }

    @Test(arguments: [4, 5])
    func missingCurrentD3D9CannotLaunchButStillRestoresItsOriginal(index: Int) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        _ = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        try FileManager.default.removeItem(at: fixture.dll(index))
        #expect(throws: MagicWineError.self) {
            try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        }
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
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
        let untouched32 = fixture.prefix.appendingPathComponent("drive_c/windows/syswow64/dxgi.dll")
        try Data("custom DXGI".utf8).write(to: untouched)
        try Data("custom 32-bit DXGI".utf8).write(to: untouched32)
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
        #expect(try Data(contentsOf: untouched32) == Data("custom 32-bit DXGI".utf8))
        #expect(try Data(contentsOf: otherDirectory.appendingPathComponent("bottle.json")) == otherMetadata)
        #expect(!FileManager.default.fileExists(atPath: otherDirectory.appendingPathComponent("graphics").path))
        let restored = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        #expect(restored.programs == saved.programs)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        #expect(try Data(contentsOf: untouched) == Data("custom DXGI".utf8))
        #expect(try Data(contentsOf: untouched32) == Data("custom 32-bit DXGI".utf8))
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
        try FileManager.default.createSymbolicLink(atPath: fixture.dll(4).path, withDestinationPath: external.path)
        // The 32-bit D3D9 DLL is originally absent.
        _ = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        let managed = try Data(contentsOf: fixture.dll(0))
        let custom = Data("user-installed replacement".utf8)
        try custom.write(to: fixture.dll(0), options: .atomic)
        try FileManager.default.removeItem(at: fixture.dll(3))
        try FileManager.default.createSymbolicLink(atPath: fixture.dll(3).path, withDestinationPath: "missing-user-target.dll")
        let customD3D9 = Data("user-installed D3D9 replacement".utf8)
        for index in 4..<6 { try customD3D9.write(to: fixture.dll(index), options: .atomic) }
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
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.dll(4).path) == external.path)
        #expect(!FileManager.default.fileExists(atPath: fixture.dll(5).path))
        let recovery = fixture.directory.appendingPathComponent("graphics/recovered")
        let enumerator = try #require(FileManager.default.enumerator(at: recovery, includingPropertiesForKeys: nil))
        var savedCustom = false
        var savedLink = false
        var recoveredD3D9: Set<String> = []
        for case let file as URL in enumerator.allObjects {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: file.path)
                savedLink = savedLink || target == "missing-user-target.dll"
            } else if attributes[.type] as? FileAttributeType == .typeRegular {
                let data = try Data(contentsOf: file)
                savedCustom = savedCustom || data == custom
                if data == customD3D9 { recoveredD3D9.insert(file.lastPathComponent) }
            }
        }
        #expect(savedCustom)
        #expect(savedLink)
        #expect(recoveredD3D9 == ["x64-d3d9.dll", "x32-d3d9.dll"])
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
        try FileManager.default.removeItem(at: fixture.component.appendingPathComponent(sources[5]))
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
        await #expect(throws: (any Error).self) {
            try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
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
        let managed = try sources.indices.map { try Data(contentsOf: fixture.dll($0)) }
        await #expect(throws: (any Error).self) {
            try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
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

    @Test func incompleteStagingFailsBeforeFileChangesAndRecoversOnFreshReads() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let old = try Data(contentsOf: fixture.metadata)
        let next = try nextMetadata(fixture, configuration: selection)
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: old, nextMetadata: next)
            try FileManager.default.removeItem(at: transaction.appendingPathComponent("after/5"))
            #expect(throws: (any Error).self) { try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory) }
            #expect(try Data(contentsOf: fixture.dll(0)) == originals[0])
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
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: old, nextMetadata: next)
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
            // Simulate a killed process: no metadata commit and no transaction cleanup.
        }
        let rollback = try await BottleStore(paths: fixture.paths).list()
        #expect(rollback.first?.graphics.backend == .standard)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
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
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
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
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: previous,
                                                         nextMetadata: next)
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
        }
        let userEdit = Data("DLL replaced by the user after an interrupted install".utf8)
        for index in [0, 4, 5] { try userEdit.write(to: fixture.dll(index), options: .atomic) }
        let current = try await BottleStore(paths: fixture.paths).current(fixture.bottle)
        #expect(current.graphics.backend == .standard)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        let recovery = fixture.directory.appendingPathComponent("graphics/recovered")
        let files = try #require(FileManager.default.enumerator(at: recovery, includingPropertiesForKeys: [.isRegularFileKey]))
        var retained: Set<String> = []
        for case let file as URL in files.allObjects {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let data = try Data(contentsOf: file)
                if data == userEdit { retained.insert(file.lastPathComponent) }
            }
        }
        #expect(retained == ["x64-d3d10core.dll", "x64-d3d9.dll", "x32-d3d9.dll"])
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

    private func metalMappings(_ backend: GraphicsBackend) -> [(source: String, destination: String)] {
        if backend == .dxmt {
            return [("x86_64-windows", "system32"), ("i386-windows", "syswow64")].flatMap { source, destination in
                ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"].map {
                    (source: "\(source)/\($0)", destination: "drive_c/windows/\(destination)/\($0)")
                }
            }
        }
        return ["d3d11.dll", "d3d12.dll", "dxgi.dll"].map {
            (source: "wine/x86_64-windows/\($0)", destination: "drive_c/windows/system32/\($0)")
        }
    }

    private func component(for backend: GraphicsBackend, fixture: Fixture) throws -> URL {
        if backend == .dxvk { return fixture.component }
        let root = fixture.paths.componentsDirectory.appendingPathComponent("test-\(backend.rawValue)")
        for mapping in metalMappings(backend) {
            let file = root.appendingPathComponent(mapping.source)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(backend.rawValue) payload \(mapping.source)".utf8).write(to: file)
        }
        return root
    }

    private var allRendererPaths: [String] {
        var paths = GraphicsPrefix.dllPaths
        for backend in [GraphicsBackend.dxmt, .d3dmetal] {
            for mapping in metalMappings(backend) where !paths.contains(mapping.destination) {
                paths.append(mapping.destination)
            }
        }
        return paths
    }

    private enum FileState: Equatable {
        case absent
        case file(Data)
        case link(String)
    }

    private func state(_ url: URL) throws -> FileState {
        // fileExists follows links, so inspect a link first to include dangling originals.
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return .link(target)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        return .file(try Data(contentsOf: url))
    }

    private func recoveredFiles(_ fixture: Fixture) throws -> [URL] {
        let root = fixture.directory.appendingPathComponent("graphics/recovered")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        return try files.allObjects.compactMap { $0 as? URL }.filter {
            try FileManager.default.attributesOfItem(atPath: $0.path)[.type] as? FileAttributeType == .typeRegular
        }
    }

    @Test func directDXVKToDXMTToD3DMetalToStandardRestoresEveryOriginalKind() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        var originals: [String: FileState] = [:]
        for (index, path) in allRendererPaths.enumerated() {
            let file = fixture.prefix.appendingPathComponent(path)
            switch index % 3 {
            case 0: try Data("original \(path)".utf8).write(to: file)
            case 1: try FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: "missing-original-\(index).dll")
            default: break
            }
            originals[path] = try state(file)
        }
        for backend in [GraphicsBackend.dxvk, .dxmt, .d3dmetal] {
            let root = try component(for: backend, fixture: fixture)
            let configuration = GraphicsConfiguration(backend: backend, componentID: root.lastPathComponent)
            _ = try await fixture.store.setGraphics(configuration, in: fixture.bottle, componentRoot: root)
            try GraphicsPrefix.validateInstalled(configuration: configuration, prefix: fixture.prefix, bottleDirectory: fixture.directory)
            let mappings = backend == .dxvk
                ? Array(zip(sources, GraphicsPrefix.dllPaths)).map { (source: $0.0, destination: $0.1) }
                : metalMappings(backend)
            for path in allRendererPaths {
                let expected: FileState
                if let mapping = mappings.first(where: { $0.destination == path }) {
                    expected = .file(try Data(contentsOf: root.appendingPathComponent(mapping.source)))
                } else {
                    expected = try #require(originals[path])
                }
                #expect(try state(fixture.prefix.appendingPathComponent(path)) == expected)
            }
        }
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        for path in allRendererPaths {
            #expect(try state(fixture.prefix.appendingPathComponent(path)) == originals[path])
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/active").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/recovered").path))
    }

    @Test(arguments: [[GraphicsBackend.dxvk, .dxmt], [.dxmt, .d3dmetal], [.d3dmetal, .dxvk]], [false, true])
    func footprintChangesRecoverOnBothSidesOfCommitAndPreserveUserEdits(backends: [GraphicsBackend], committed: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        var originals: [String: Data] = [:]
        for path in allRendererPaths {
            let data = Data("pre-renderer \(path)".utf8)
            try data.write(to: fixture.prefix.appendingPathComponent(path))
            originals[path] = data
        }
        let oldRoot = try component(for: backends[0], fixture: fixture)
        let newRoot = try component(for: backends[1], fixture: fixture)
        let previous = GraphicsConfiguration(backend: backends[0], componentID: oldRoot.lastPathComponent)
        let next = GraphicsConfiguration(backend: backends[1], componentID: newRoot.lastPathComponent)
        _ = try await fixture.store.setGraphics(previous, in: fixture.bottle, componentRoot: oldRoot)
        let before = try allRendererPaths.map { try state(fixture.prefix.appendingPathComponent($0)) }
        let oldMetadata = try Data(contentsOf: fixture.metadata)
        let newMetadata = try nextMetadata(fixture, configuration: next)
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: previous, to: next, componentRoot: newRoot,
                                                         bottleDirectory: fixture.directory, previousMetadata: oldMetadata,
                                                         nextMetadata: newMetadata)
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
            if committed { try newMetadata.write(to: fixture.metadata, options: .atomic) }
        }
        let changed = fixture.prefix.appendingPathComponent("drive_c/windows/system32/d3d11.dll")
        let replacement = Data("user replacement after interrupted backend switch".utf8)
        try replacement.write(to: changed, options: .atomic)
        let current = try await BottleStore(paths: fixture.paths).current(fixture.bottle)
        #expect(current.graphics == (committed ? next : previous))
        if committed {
            #expect(try Data(contentsOf: changed) == replacement)
        } else {
            for (index, path) in allRendererPaths.enumerated() {
                #expect(try state(fixture.prefix.appendingPathComponent(path)) == before[index])
            }
        }
        _ = try await fixture.store.setGraphics(.init(), in: current, componentRoot: nil)
        for path in allRendererPaths {
            #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent(path)) == originals[path])
        }
        #expect(try recoveredFiles(fixture).contains { try Data(contentsOf: $0) == replacement })
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/transaction").path))
    }

    @Test func legacyFourDLLToDXMTRollbackUsesTheOutgoingSubsetNotTheUnion() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try installHistoricalFourDLLs(fixture)
        let independentD3D9 = Data("independently installed D3D9".utf8)
        try independentD3D9.write(to: fixture.dll(4), options: .atomic)
        let root = try component(for: .dxmt, fixture: fixture)
        let next = GraphicsConfiguration(backend: .dxmt, componentID: root.lastPathComponent)
        let previousMetadata = try Data(contentsOf: fixture.metadata)
        let nextData = try nextMetadata(fixture, configuration: next)
        let manifestURL = fixture.directory.appendingPathComponent("graphics/active/manifest.json")
        let historicalManifest = try Data(contentsOf: manifestURL)
        let managed = try (0..<4).map { try Data(contentsOf: fixture.dll($0)) }
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: selection, to: next, componentRoot: root,
                                                         bottleDirectory: fixture.directory, previousMetadata: previousMetadata,
                                                         nextMetadata: nextData)
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
        }
        _ = try await fixture.store.current(fixture.bottle)
        #expect(try Data(contentsOf: manifestURL) == historicalManifest)
        for index in 0..<4 { #expect(try Data(contentsOf: fixture.dll(index)) == managed[index]) }
        #expect(try Data(contentsOf: fixture.dll(4)) == independentD3D9)
        for mapping in metalMappings(.dxmt) where !GraphicsPrefix.dllPaths.contains(mapping.destination) {
            #expect(try state(fixture.prefix.appendingPathComponent(mapping.destination)) == .absent)
        }
        _ = try await fixture.store.setGraphics(next, in: fixture.bottle, componentRoot: root)
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        for index in 0..<4 { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        #expect(try Data(contentsOf: fixture.dll(4)) == independentD3D9)
        #expect(try Data(contentsOf: fixture.dll(5)) == originals[5])
    }

    @Test(arguments: [GraphicsBackend.dxmt, .d3dmetal])
    func metalHUDChangesNeverRewriteAndComponentUpdatesRemainExplicit(backend: GraphicsBackend) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let root = try component(for: backend, fixture: fixture)
        var configuration = GraphicsConfiguration(backend: backend, componentID: root.lastPathComponent)
        _ = try await fixture.store.setGraphics(configuration, in: fixture.bottle, componentRoot: root)
        let file = fixture.prefix.appendingPathComponent("drive_c/windows/system32/d3d11.dll")
        let custom = Data("replacement must survive HUD-only selection".utf8)
        try custom.write(to: file, options: .atomic)
        let manifest = fixture.directory.appendingPathComponent("graphics/active/manifest.json")
        let savedManifest = try Data(contentsOf: manifest)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try FileManager.default.removeItem(at: root)
        configuration.showHUD = true
        _ = try await fixture.store.setGraphics(configuration, in: fixture.bottle, componentRoot: nil)
        let updatedAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((updatedAttributes[.systemFileNumber] as? NSNumber) == (attributes[.systemFileNumber] as? NSNumber))
        #expect(try Data(contentsOf: file) == custom)
        #expect(try Data(contentsOf: manifest) == savedManifest)
        let updated = GraphicsConfiguration(backend: backend, componentID: "different-component")
        await #expect(throws: MagicWineError.self) {
            try await fixture.store.setGraphics(updated, in: fixture.bottle, componentRoot: nil)
        }
        #expect(try await fixture.store.current(fixture.bottle).graphics == configuration)
        #expect(try Data(contentsOf: file) == custom)
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        #expect(try state(file) == .absent)
        #expect(try recoveredFiles(fixture).contains { try Data(contentsOf: $0) == custom })
    }

    @Test func directSwitchesPreserveDisplacedOverlapOutgoingOnlyAndIncomingOriginals() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        var originals: [String: Data] = [:]
        for path in allRendererPaths {
            let data = Data("original \(path)".utf8)
            try data.write(to: fixture.prefix.appendingPathComponent(path))
            originals[path] = data
        }
        _ = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        let customD3D9 = Data("displaced outgoing-only D3D9".utf8)
        let customD3D11 = Data("displaced overlapping D3D11".utf8)
        try customD3D9.write(to: fixture.dll(4), options: .atomic)
        try customD3D11.write(to: fixture.dll(1), options: .atomic)
        let dxgiPath = "drive_c/windows/system32/dxgi.dll"
        let incomingOriginal = Data("incoming-only user DXGI is the original".utf8)
        try incomingOriginal.write(to: fixture.prefix.appendingPathComponent(dxgiPath), options: .atomic)
        originals[dxgiPath] = incomingOriginal
        let dxmt = try component(for: .dxmt, fixture: fixture)
        _ = try await fixture.store.setGraphics(.init(backend: .dxmt, componentID: dxmt.lastPathComponent),
                                                in: fixture.bottle, componentRoot: dxmt)
        #expect(try Data(contentsOf: fixture.dll(4)) == originals[GraphicsPrefix.dllPaths[4]])
        let winemetalPath = "drive_c/windows/system32/winemetal.dll"
        let customWineMetal = Data("displaced outgoing-only winemetal".utf8)
        try customWineMetal.write(to: fixture.prefix.appendingPathComponent(winemetalPath), options: .atomic)
        try FileManager.default.removeItem(at: fixture.dll(1))
        try FileManager.default.createSymbolicLink(atPath: fixture.dll(1).path, withDestinationPath: "custom-missing-d3d11.dll")
        let d3dmetal = try component(for: .d3dmetal, fixture: fixture)
        _ = try await fixture.store.setGraphics(.init(backend: .d3dmetal, componentID: d3dmetal.lastPathComponent),
                                                in: fixture.bottle, componentRoot: d3dmetal)
        #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent(winemetalPath)) == originals[winemetalPath])
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        for path in allRendererPaths {
            #expect(try Data(contentsOf: fixture.prefix.appendingPathComponent(path)) == originals[path])
        }
        let recovered = try recoveredFiles(fixture).map { try Data(contentsOf: $0) }
        for displaced in [customD3D9, customD3D11, customWineMetal] { #expect(recovered.contains(displaced)) }
        #expect(!recovered.contains(incomingOriginal))
        let directory = fixture.directory.appendingPathComponent("graphics/recovered")
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        #expect(enumerator.allObjects.compactMap { $0 as? URL }.contains {
            (try? FileManager.default.destinationOfSymbolicLink(atPath: $0.path)) == "custom-missing-d3d11.dll"
        })
    }

    @Test(arguments: ["unknown", "duplicate", "traversal", "missing", "version", "hash"])
    func malformedPathManifestsRetainFilesAndOriginals(attack: String) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let root = try component(for: .d3dmetal, fixture: fixture)
        let configuration = GraphicsConfiguration(backend: .d3dmetal, componentID: root.lastPathComponent)
        _ = try await fixture.store.setGraphics(configuration, in: fixture.bottle, componentRoot: root)
        let manifest = fixture.directory.appendingPathComponent("graphics/active/manifest.json")
        let valid = try Data(contentsOf: manifest)
        let metadata = try Data(contentsOf: fixture.metadata)
        let before = try allRendererPaths.map { try state(fixture.prefix.appendingPathComponent($0)) }
        var json = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        var paths = try #require(json["paths"] as? [String])
        switch attack {
        case "unknown": paths[0] = "drive_c/windows/system32/user.dll"
        case "duplicate": paths[1] = paths[0]
        case "traversal": paths[0] = "drive_c/windows/system32/../../../bottle.json"
        case "missing": paths.removeLast()
        case "version": json["schema"] = 999
        default:
            var entries = try #require(json["entries"] as? [[String: Any]])
            entries[0]["installedHash"] = "not-a-digest"
            json["entries"] = entries
        }
        json["paths"] = paths
        let corrupted = try JSONSerialization.data(withJSONObject: json)
        try corrupted.write(to: manifest, options: .atomic)
        #expect(throws: (any Error).self) {
            try GraphicsPrefix.validateInstalled(configuration: configuration, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        }
        await #expect(throws: (any Error).self) {
            try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        }
        for (index, path) in allRendererPaths.enumerated() {
            #expect(try state(fixture.prefix.appendingPathComponent(path)) == before[index])
        }
        #expect(try Data(contentsOf: manifest) == corrupted)
        #expect(try Data(contentsOf: fixture.metadata) == metadata)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics/transaction").path))
        try valid.write(to: manifest, options: .atomic)
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
    }

    @Test(arguments: ["unknown", "duplicate", "missing", "version", "fingerprint", "subset"])
    func malformedPathJournalsFailBeforeMutationAndRetainRecoveryEvidence(attack: String) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let oldRoot = try component(for: .dxmt, fixture: fixture)
        let newRoot = try component(for: .d3dmetal, fixture: fixture)
        let previous = GraphicsConfiguration(backend: .dxmt, componentID: oldRoot.lastPathComponent)
        let next = GraphicsConfiguration(backend: .d3dmetal, componentID: newRoot.lastPathComponent)
        _ = try await fixture.store.setGraphics(previous, in: fixture.bottle, componentRoot: oldRoot)
        let before = try allRendererPaths.map { try state(fixture.prefix.appendingPathComponent($0)) }
        let previousData = try Data(contentsOf: fixture.metadata)
        let nextData = try nextMetadata(fixture, configuration: next)
        let journalURL = fixture.directory.appendingPathComponent("graphics/transaction/journal.json")
        let valid = try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: previous, to: next, componentRoot: newRoot,
                                                         bottleDirectory: fixture.directory, previousMetadata: previousData,
                                                         nextMetadata: nextData)
            let data = try Data(contentsOf: journalURL)
            var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var paths = try #require(json["paths"] as? [String])
            switch attack {
            case "unknown": paths[0] = "/tmp/unowned.dll"
            case "duplicate": paths[1] = paths[0]
            case "missing": paths.removeLast()
            case "version": json["schema"] = 999
            case "subset": json["previousPaths"] = Array(try #require(json["previousPaths"] as? [String]).dropLast())
            default:
                var snapshots = try #require(json["before"] as? [[String: Any]])
                snapshots[0]["fingerprint"] = "file:invalid"
                json["before"] = snapshots
            }
            json["paths"] = paths
            try JSONSerialization.data(withJSONObject: json).write(to: journalURL, options: .atomic)
            #expect(throws: (any Error).self) { try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory) }
            return data
        }
        let corrupted = try Data(contentsOf: journalURL)
        await #expect(throws: (any Error).self) { try await fixture.store.current(fixture.bottle) }
        #expect(try Data(contentsOf: journalURL) == corrupted)
        #expect(try Data(contentsOf: fixture.metadata) == previousData)
        for (index, path) in allRendererPaths.enumerated() {
            #expect(try state(fixture.prefix.appendingPathComponent(path)) == before[index])
        }
        try valid.write(to: journalURL, options: .atomic)
        #expect(try await fixture.store.current(fixture.bottle).graphics == previous)
    }

    @Test(arguments: ["before", "after", "before-active/originals", "after-active/originals"])
    func stagedSymlinkParentsCannotRedirectApplicationOrRollback(path: String) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let oldRoot = try component(for: .dxmt, fixture: fixture)
        let newRoot = try component(for: .d3dmetal, fixture: fixture)
        let previous = GraphicsConfiguration(backend: .dxmt, componentID: oldRoot.lastPathComponent)
        let next = GraphicsConfiguration(backend: .d3dmetal, componentID: newRoot.lastPathComponent)
        _ = try await fixture.store.setGraphics(previous, in: fixture.bottle, componentRoot: oldRoot)
        let before = try allRendererPaths.map { try state(fixture.prefix.appendingPathComponent($0)) }
        let oldData = try Data(contentsOf: fixture.metadata)
        let nextData = try nextMetadata(fixture, configuration: next)
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: previous, to: next, componentRoot: newRoot,
                                                         bottleDirectory: fixture.directory, previousMetadata: oldData,
                                                         nextMetadata: nextData)
            let redirected = transaction.appendingPathComponent(path)
            let outside = fixture.paths.root.appendingPathComponent("outside-stage")
            try FileManager.default.moveItem(at: redirected, to: outside)
            try FileManager.default.createSymbolicLink(at: redirected, withDestinationURL: outside)
            #expect(throws: (any Error).self) { try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory) }
            if path.hasPrefix("before") {
                #expect(throws: (any Error).self) { try GraphicsPrefix.recover(bottleDirectory: fixture.directory) }
            }
            for (index, path) in allRendererPaths.enumerated() {
                #expect(try state(fixture.prefix.appendingPathComponent(path)) == before[index])
            }
            try FileManager.default.removeItem(at: redirected)
            try FileManager.default.moveItem(at: outside, to: redirected)
        }
        #expect(try await fixture.store.current(fixture.bottle).graphics == previous)
    }

    @Test(arguments: [GraphicsBackend.dxmt, .d3dmetal])
    func metalSourceSymlinkAncestorsFailWithoutPrefixChanges(backend: GraphicsBackend) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let root = try component(for: backend, fixture: fixture)
        let sourceDirectory = root.appendingPathComponent(backend == .dxmt ? "x86_64-windows" : "wine")
        let outside = fixture.paths.root.appendingPathComponent("outside-component")
        try FileManager.default.moveItem(at: sourceDirectory, to: outside)
        try FileManager.default.createSymbolicLink(at: sourceDirectory, withDestinationURL: outside)
        let configuration = GraphicsConfiguration(backend: backend, componentID: root.lastPathComponent)
        let metadata = try Data(contentsOf: fixture.metadata)
        await #expect(throws: (any Error).self) {
            try await fixture.store.setGraphics(configuration, in: fixture.bottle, componentRoot: root)
        }
        for path in allRendererPaths { #expect(try state(fixture.prefix.appendingPathComponent(path)) == .absent) }
        #expect(try Data(contentsOf: fixture.metadata) == metadata)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("graphics").path))
    }

    @Test func legacySixDLLInstallJournalAndManifestRemainRestorable() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.paths.root) }
        let originals = try writeOriginals(fixture)
        let previous = try Data(contentsOf: fixture.metadata)
        let next = try nextMetadata(fixture, configuration: selection)
        try await GraphicsPrefix.withLock(bottleDirectory: fixture.directory) {
            let transaction = try GraphicsPrefix.prepare(from: .init(), to: selection, componentRoot: fixture.component,
                                                         bottleDirectory: fixture.directory, previousMetadata: previous,
                                                         nextMetadata: next)
            for path in ["journal.json", "after-active/manifest.json"] {
                let url = transaction.appendingPathComponent(path)
                var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                for key in ["schema", "backend", "paths", "previousPaths", "nextPaths"] { json.removeValue(forKey: key) }
                try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
            }
            try GraphicsPrefix.apply(transaction: transaction, bottleDirectory: fixture.directory)
        }
        #expect(try await fixture.store.current(fixture.bottle).graphics.backend == .standard)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
        _ = try await fixture.store.setGraphics(selection, in: fixture.bottle, componentRoot: fixture.component)
        let manifest = fixture.directory.appendingPathComponent("graphics/active/manifest.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        for key in ["schema", "backend", "paths"] { json.removeValue(forKey: key) }
        try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
        try GraphicsPrefix.validateInstalled(configuration: selection, prefix: fixture.prefix, bottleDirectory: fixture.directory)
        _ = try await fixture.store.setGraphics(.init(), in: fixture.bottle, componentRoot: nil)
        for index in originals.indices { #expect(try Data(contentsOf: fixture.dll(index)) == originals[index]) }
    }
}
