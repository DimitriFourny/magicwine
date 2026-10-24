import Foundation
import Testing
@testable import MagicWineCore

/// `bottle.json` versions: legacy records migrate, current ones round-trip, newer ones are refused.
struct BottleSchemaTests {
    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let bottle: Bottle

        init() async throws {
            paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            store = BottleStore(paths: paths)
            bottle = try await store.create(name: "Schema", runtime: RuntimeDescriptor(
                executableURL: URL(fileURLWithPath: "/opt/wine/bin/wine"), version: "wine-11.0"))
        }

        var metadata: URL {
            paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString).appendingPathComponent("bottle.json")
        }

        func json() throws -> [String: Any] {
            try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        }

        func write(_ json: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]).write(to: metadata, options: .atomic)
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    /// The first records: no format version and none of the fields added since.
    private static let laterFields = ["schemaVersion", "graphics", "display", "msyncEnabled", "compatibility", "dependencies"]

    @Test func currentRecordsCarryTheirVersionAndRoundTrip() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let json = try fixture.json()
        #expect(json["schemaVersion"] as? Int == Bottle.currentSchemaVersion)
        for key in Self.laterFields { #expect(json[key] != nil, "\(key)") }

        var bottle = fixture.bottle
        var program = WindowsProgram(name: "Game", executablePath: "/tmp/game.exe", arguments: ["-windowed"])
        program.lastLaunchedAt = Date(timeIntervalSinceReferenceDate: 800_000_100)
        program.playTime = 3_600.5
        program.isFavorite = true
        bottle.programs = [program]
        bottle.graphics = GraphicsConfiguration(backend: .dxvk, componentID: DXVKInstallation.componentID, showHUD: true)
        bottle.msyncEnabled = false
        bottle.display = DisplayConfiguration(retinaEnabled: false)
        bottle.compatibility = CompatibilityOptions(advertiseAVX: true, wineDebug: .wineDefault, dxvkHUD: .fps)
        bottle.dependencies = [InstalledDependency(id: "vcrun2022", version: "14.44.35211",
                                                   installedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))]
        let decoded = try JSONDecoder().decode(Bottle.self, from: JSONEncoder().encode(bottle))
        #expect(decoded == bottle)
        #expect(decoded.hasDisplayConfiguration)
    }

    @Test func legacyRecordsMigrateWithTheMeaningTheyHadThen() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var legacy = try fixture.json()
        for key in Self.laterFields { legacy.removeValue(forKey: key) }
        // A program saved before launch options, play history and favorites existed.
        let programID = UUID()
        legacy["programs"] = [["id": programID.uuidString, "name": "Game", "executablePath": "/tmp/game.exe"]]
        let data = try JSONSerialization.data(withJSONObject: legacy)

        let migrated = try JSONDecoder().decode(Bottle.self, from: data)
        #expect(migrated.id == fixture.bottle.id && migrated.name == fixture.bottle.name)
        #expect(migrated.graphics == GraphicsConfiguration())
        #expect(migrated.msyncEnabled)
        #expect(!migrated.hasDisplayConfiguration)
        #expect(migrated.compatibility == CompatibilityOptions())
        #expect(migrated.dependencies.isEmpty)
        let program = try #require(migrated.programs.first)
        #expect(program.id == programID && program.arguments.isEmpty && program.environment.isEmpty)
        #expect(program.lastLaunchedAt == nil && program.playTime == 0 && !program.isFavorite)
        // Each later field may be missing on its own, as records gained them one by one.
        for key in Self.laterFields {
            var partial = try fixture.json()
            partial.removeValue(forKey: key)
            let decoded = try JSONDecoder().decode(Bottle.self, from: JSONSerialization.data(withJSONObject: partial))
            #expect(decoded.id == fixture.bottle.id, "\(key)")
        }

        // Reading never rewrites the record; the store adopts the prefix's display (none: the default).
        try data.write(to: fixture.metadata, options: .atomic)
        let loaded = try await fixture.store.current(fixture.bottle)
        #expect(loaded.display == DisplayConfiguration())
        #expect(try await fixture.store.list().map(\.id) == [fixture.bottle.id])
        #expect(try Data(contentsOf: fixture.metadata) == data)

        // The next metadata write saves the current version with every migrated value.
        let saved = try await fixture.store.setCompatibility(CompatibilityOptions(advertiseAVX: true), in: loaded)
        let json = try fixture.json()
        #expect(json["schemaVersion"] as? Int == Bottle.currentSchemaVersion)
        for key in Self.laterFields { #expect(json[key] != nil, "\(key)") }
        #expect(try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: fixture.metadata)) == saved)
        #expect(saved.msyncEnabled && saved.graphics == GraphicsConfiguration() && saved.compatibility.advertiseAVX)
        #expect(saved.programs.map(\.id) == [programID])

        // Play history of the migrated program is then saved in the current version too.
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        _ = try await fixture.store.recordLaunch(of: programID, at: started, in: saved)
        _ = try await fixture.store.addPlayTime(42, to: programID, in: saved)
        let played = try await fixture.store.setFavorite(true, programID: programID, in: saved)
        let reread = try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: fixture.metadata))
        #expect(reread == played)
        #expect(reread.programs.first?.lastLaunchedAt == started && reread.programs.first?.playTime == 42 &&
                reread.programs.first?.isFavorite == true)
    }

    @Test func newerRecordsAreRefusedAndLeftUnchanged() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        var json = try fixture.json()
        json["schemaVersion"] = Bottle.currentSchemaVersion + 1
        json["fieldOfALaterVersion"] = ["kept": true]
        try fixture.write(json)
        let original = try Data(contentsOf: fixture.metadata)

        func expectNewer(_ operation: () async throws -> Void) async {
            do {
                try await operation()
                Issue.record("A newer bottle format was accepted.")
            } catch MagicWineError.newerVersion {
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        await expectNewer { _ = try JSONDecoder().decode(Bottle.self, from: original) }
        await expectNewer { _ = try await fixture.store.list() }
        await expectNewer { _ = try await fixture.store.current(fixture.bottle) }
        await expectNewer { _ = try await fixture.store.setCompatibility(CompatibilityOptions(advertiseAVX: true), in: fixture.bottle) }
        var renamed = fixture.bottle
        renamed.name = "Renamed"
        await expectNewer { try await fixture.store.save(renamed) }
        #expect(try Data(contentsOf: fixture.metadata) == original)
    }

    @Test func malformedVersionsAreInvalid() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let invalid: [Any] = [-1, "1", NSNull(), 1.5]
        for version in invalid {
            var json = try fixture.json()
            json["schemaVersion"] = version
            #expect(throws: DecodingError.self, "\(version)") {
                try JSONDecoder().decode(Bottle.self, from: JSONSerialization.data(withJSONObject: json))
            }
        }
    }
}
