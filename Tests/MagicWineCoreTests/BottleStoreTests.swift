import Foundation
import Testing
@testable import MagicWineCore

struct BottleStoreTests {
    private func fixture() throws -> (ApplicationPaths, BottleStore) {
        let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.prepare()
        return (paths, BottleStore(paths: paths))
    }

    private let runtime = RuntimeDescriptor(executableURL: URL(fileURLWithPath: "/opt/wine/bin/wine"), version: "wine-11")

    @Test func bottleNamesNeverBecomePathsAndInitializationPersists() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var bottle = try await store.create(name: " ../Shared / Windows ", runtime: runtime)
        #expect(bottle.name == "../Shared / Windows")
        #expect(store.prefixURL(for: bottle).deletingLastPathComponent().lastPathComponent == bottle.id.uuidString)
        #expect(store.prefixURL(for: bottle).deletingLastPathComponent().deletingLastPathComponent() == paths.bottlesDirectory)
        bottle.isInitialized = true
        try await store.save(bottle)
        let reopened = BottleStore(paths: paths)
        let loaded = try await reopened.list()
        #expect(loaded == [bottle])
        #expect(loaded[0].runtime == runtime)
    }

    @Test func staleRegistrationsPreserveOtherProgramsAndUnregisterDoesNotDeleteFiles() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = try await store.create(name: "Apps", runtime: runtime)
        let first = paths.root.appendingPathComponent("First App.exe")
        let second = paths.root.appendingPathComponent("Second App.EXE")
        try Data([0x4d, 0x5a]).write(to: first)
        try Data([0x4d, 0x5a]).write(to: second)
        _ = try await store.registerProgram(in: bottle, executableURL: first)
        let updated = try await store.registerProgram(in: bottle, executableURL: second)
        #expect(Set(updated.programs.map(\.executablePath)) == Set([first.path, second.path]))
        let duplicate = try await store.registerProgram(in: bottle, executableURL: first)
        #expect(duplicate.programs == updated.programs)
        let removed = try await store.removeProgram(id: updated.programs[0].id, in: bottle)
        #expect(removed.programs.map(\.id) == [updated.programs[1].id])
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func shortcutDiscoverySkipsExternalSymlinksAndUninstallers() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = try await store.create(name: "Shortcuts", runtime: runtime)
        let menu = store.prefixURL(for: bottle).appendingPathComponent("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs")
        let external = paths.root.appendingPathComponent("External")
        try FileManager.default.createDirectory(at: menu, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data([1]).write(to: menu.appendingPathComponent("Editor.lnk"))
        try Data([1]).write(to: menu.appendingPathComponent("Uninstall Editor.lnk"))
        try Data([1]).write(to: external.appendingPathComponent("Outside.lnk"))
        try FileManager.default.createSymbolicLink(at: menu.appendingPathComponent("Linked"), withDestinationURL: external)
        let discovered = try await store.discoverPrograms(in: bottle)
        #expect(discovered.programs.map(\.name) == ["Editor"])
        let rediscovered = try await store.discoverPrograms(in: bottle)
        #expect(rediscovered.programs == discovered.programs)
    }

    @Test func alteredBottleIdentityIsRejectedInsteadOfOverwritingMetadata() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = try await store.create(name: "Safe", runtime: runtime)
        let directory = store.prefixURL(for: bottle).deletingLastPathComponent()
        let replacement = Bottle(name: "Foreign", runtime: runtime)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(replacement).write(to: directory.appendingPathComponent("bottle.json"))
        await #expect(throws: MagicWineError.self) { try await store.save(bottle) }
        let data = try Data(contentsOf: directory.appendingPathComponent("bottle.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(Bottle.self, from: data).id == replacement.id)
    }
}
