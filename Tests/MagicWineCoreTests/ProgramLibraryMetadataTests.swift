import Foundation
import Testing
@testable import MagicWineCore

/// Play history and favorites: metadata-only `BottleStore` transitions and their decoding.
struct ProgramLibraryMetadataTests {
    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let bottle: Bottle
        let program: WindowsProgram

        init() async throws {
            paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            store = BottleStore(paths: paths)
            let created = try await store.create(
                name: "Games", runtime: RuntimeDescriptor(executableURL: URL(fileURLWithPath: "/opt/wine/bin/wine"), version: "wine-11"))
            let executable = store.prefixURL(for: created).appendingPathComponent("drive_c/Games/game.exe")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: executable)
            bottle = try await store.registerProgram(in: created, executableURL: executable)
            program = try #require(bottle.programs.first)
        }

        func saved() async throws -> WindowsProgram {
            try #require(try await BottleStore(paths: paths).list().first?.programs.first)
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    @Test func recordsWithoutHistoryDecodeAsNeverLaunchedAndEncodeUnchanged() throws {
        let legacy = Data(#"{"id":"6A1F4B44-5C0B-4C55-9E5A-2B8E1D7E2F10","name":"Game","executablePath":"/games/game.exe"}"#.utf8)
        let program = try JSONDecoder().decode(WindowsProgram.self, from: legacy)
        #expect(program.lastLaunchedAt == nil)
        #expect(program.playTime == 0)
        #expect(!program.isFavorite)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(program)) as? [String: Any]
        #expect(Set(encoded?.keys.map { $0 } ?? []) == ["id", "name", "executablePath"])

        let negative = Data(#"{"id":"6A1F4B44-5C0B-4C55-9E5A-2B8E1D7E2F10","name":"Game","executablePath":"/games/game.exe","playTime":-5}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WindowsProgram.self, from: negative) }
    }

    @Test func launchesPlayTimeAndFavoritesPersistAndAccumulate() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        _ = try await fixture.store.recordLaunch(of: fixture.program.id, at: started, in: fixture.bottle)
        _ = try await fixture.store.addPlayTime(90, to: fixture.program.id, in: fixture.bottle)
        let updated = try await fixture.store.addPlayTime(30.5, to: fixture.program.id, in: fixture.bottle)
        #expect(updated.programs.first?.playTime == 120.5)
        _ = try await fixture.store.setFavorite(true, programID: fixture.program.id, in: fixture.bottle)

        let saved = try await fixture.saved()
        #expect(saved.lastLaunchedAt == started)
        #expect(saved.playTime == 120.5)
        #expect(saved.isFavorite)
        #expect(saved.withLibraryMetadata(of: fixture.program) == fixture.program)

        _ = try await fixture.store.setFavorite(false, programID: fixture.program.id, in: fixture.bottle)
        #expect(try await fixture.saved().isFavorite == false)
    }

    @Test func invalidSessionsAndUnknownProgramsChangeNothing() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.store.addPlayTime(60, to: fixture.program.id, in: fixture.bottle)
        for duration in [-1, .nan, .infinity] as [TimeInterval] {
            await #expect(throws: MagicWineError.self) {
                try await fixture.store.addPlayTime(duration, to: fixture.program.id, in: fixture.bottle)
            }
        }
        #expect(try await fixture.saved().playTime == 60)

        // A program removed while it ran is not recorded; favoriting it is refused.
        let removed = UUID()
        let unchanged = try await fixture.store.addPlayTime(10, to: removed, in: fixture.bottle)
        #expect(unchanged.programs == [try await fixture.saved()])
        _ = try await fixture.store.recordLaunch(of: removed, at: Date(), in: fixture.bottle)
        await #expect(throws: MagicWineError.self) {
            try await fixture.store.setFavorite(true, programID: removed, in: fixture.bottle)
        }
        #expect(try await fixture.saved().lastLaunchedAt == nil)
    }

    @Test func editorsAndGeneralSavesKeepHistoryRecordedMeanwhile() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        // The editor and a general save start from records without history.
        let original = fixture.program
        let staleBottle = fixture.bottle
        let started = Date(timeIntervalSinceReferenceDate: 800_000_000)
        _ = try await fixture.store.recordLaunch(of: original.id, at: started, in: fixture.bottle)
        _ = try await fixture.store.addPlayTime(45, to: original.id, in: fixture.bottle)
        _ = try await fixture.store.setFavorite(true, programID: original.id, in: fixture.bottle)

        var edited = original
        edited.name = "Game (windowed)"
        edited.arguments = ["-windowed"]
        let updated = try await fixture.store.updateProgram(edited, from: original, in: fixture.bottle)
        let saved = try #require(updated.programs.first)
        #expect(saved.name == "Game (windowed)")
        #expect(saved.arguments == ["-windowed"])
        #expect(saved.lastLaunchedAt == started)
        #expect(saved.playTime == 45)
        #expect(saved.isFavorite)

        // A stale general save neither fails on nor erases the history.
        var renamed = staleBottle
        renamed.name = "Library"
        renamed.programs[0] = saved.withLibraryMetadata(of: original)
        try await fixture.store.save(renamed)
        let afterSave = try await fixture.saved()
        #expect(afterSave == saved)
        #expect(try await fixture.store.list().first?.name == "Library")

        // History never makes a general save able to change launch options.
        var bypass = renamed
        bypass.programs[0].arguments = []
        await #expect(throws: MagicWineError.self) { try await fixture.store.save(bypass) }
        #expect(try await fixture.saved() == saved)
    }
}
