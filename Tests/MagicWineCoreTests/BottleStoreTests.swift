import Foundation
import Testing
@testable import MagicWineCore

struct BottleStoreTests {
    private func fixture() throws -> (ApplicationPaths, BottleStore) {
        let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString))
        try paths.prepare()
        return (paths, BottleStore(paths: paths))
    }

    private let runtime = RuntimeDescriptor(executableURL: URL(fileURLWithPath: "/opt/wine/bin/wine"), version: "wine-11")

    private func writeFile(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// A real Shell Link header, local-volume LinkInfo and Unicode StringData.
    private func shortcut(target: String = "C:\\Apps\\Steam\\steam.exe",
                          arguments: String? = nil, working: String = "C:\\Apps\\Steam",
                          show: UInt32 = 1, runAs: Bool = false, icon: String? = nil) -> Data {
        func put(_ value: UInt32, in data: inout Data, at offset: Int) {
            for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        var info = Data(repeating: 0, count: 28)
        put(28, in: &info, at: 4)
        put(1, in: &info, at: 8)
        put(28, in: &info, at: 12)
        var volume = Data(repeating: 0, count: 17)
        put(17, in: &volume, at: 0)
        put(3, in: &volume, at: 4)
        put(16, in: &volume, at: 12)
        info.append(volume)
        put(UInt32(info.count), in: &info, at: 16)
        info.append(contentsOf: (target + "\0").utf8)
        put(UInt32(info.count), in: &info, at: 24)
        info.append(0)
        put(UInt32(info.count), in: &info, at: 0)

        var data = Data(repeating: 0, count: 76)
        put(76, in: &data, at: 0)
        data.replaceSubrange(4..<20, with: [1, 0x14, 2, 0, 0, 0, 0, 0, 0xc0, 0, 0, 0, 0, 0, 0, 0x46])
        var flags: UInt32 = 0x82 | (runAs ? 0x2000 : 0)
        put(show, in: &data, at: 60)
        data.append(info)
        for (flag, value) in [(UInt32(16), Optional(working)), (32, arguments), (64, icon)] {
            guard let value else { continue }
            flags |= flag
            let encoded = value.data(using: .utf16LittleEndian)!
            let count = encoded.count / 2
            data.append(UInt8(truncatingIfNeeded: count))
            data.append(UInt8(truncatingIfNeeded: count >> 8))
            data.append(encoded)
        }
        put(flags, in: &data, at: 20)
        data.append(Data(repeating: 0, count: 4))
        return data
    }

    private func internetShortcut(_ target: String, icon: String = "C:\\Icons\\Game.ico") -> Data {
        Data("[InternetShortcut]\r\nURL=\(target)\r\nIconFile=\(icon)\r\n".utf8)
    }

    private func writeLegacyMetadata(_ bottle: Bottle, store: BottleStore) throws {
        try JSONEncoder().encode(bottle).write(
            to: store.prefixURL(for: bottle).deletingLastPathComponent().appendingPathComponent("bottle.json"))
    }

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
        let second = paths.root.appendingPathComponent("Second App.URL")
        try Data([0x4d, 0x5a]).write(to: first)
        try Data("[InternetShortcut]\r\nURL=steam://rungameid/4369130\r\n".utf8).write(to: second)
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

    @Test func internetShortcutsAreDiscoveredOnlyInLauncherFolders() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = try await store.create(name: "Steam", runtime: runtime)
        let drive = store.prefixURL(for: bottle).appendingPathComponent("drive_c")
        let included = [
            "ProgramData/Microsoft/Windows/Start Menu/Programs/Shared.url",
            "users/player/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/Steam/Chop Chop Inc..url",
            "users/player/Desktop/Desktop Game.URL",
            "users/Public/Desktop/Public Game.url"
        ]
        let excluded = [
            "users/player/Documents/Document.url",
            "users/player/AppData/Local/Cache.url",
            "users/player/Desktop/Uninstall Game.url"
        ]
        for (index, path) in (included + excluded).enumerated() {
            let shortcut = drive.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: shortcut.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("[InternetShortcut]\r\nURL=steam://rungameid/\(4369130 + index)\r\n".utf8).write(to: shortcut)
        }
        let discovered = try await store.discoverPrograms(in: bottle)
        let discoveredPaths = Set(discovered.programs.map { URL(fileURLWithPath: $0.executablePath).resolvingSymlinksInPath().path })
        #expect(discoveredPaths == Set(included.map { drive.appendingPathComponent($0).resolvingSymlinksInPath().path }))
        #expect(discovered.programs.map(\.name) == ["Chop Chop Inc.", "Desktop Game", "Public Game", "Shared"])
        let refreshed = try await store.discoverPrograms(in: bottle)
        #expect(refreshed.programs == discovered.programs)
    }

    @Test func reopeningNormalizesLegacyLaunchersAndRemovalCannotRevealHiddenDuplicates() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var bottle = try await store.create(name: "Legacy", runtime: runtime)
        let prefix = store.prefixURL(for: bottle)
        try writeFile(Data([0x4d, 0x5a]), to: prefix.appendingPathComponent("drive_c/Apps/Steam/steam.exe"))
        let links = ["Desktop Steam.lnk", "Shared Steam.lnk", "User Steam.lnk"].map { paths.root.appendingPathComponent($0) }
        for (index, link) in links.enumerated() {
            try writeFile(shortcut(arguments: index == 0 ? nil : "", icon: "C:\\Icons\\\(index).ico"), to: link)
        }
        let urls = ["First Game.url", "Second Game.URL"].map { paths.root.appendingPathComponent($0) }
        for url in urls { try writeFile(internetShortcut("steam://rungameid/4369130"), to: url) }
        let first = WindowsProgram(name: "My Steam", executablePath: links[0].path)
        let game = WindowsProgram(name: "My Game", executablePath: urls[0].path)
        bottle.programs = [
            first,
            WindowsProgram(name: "Steam", executablePath: links[1].path),
            game,
            WindowsProgram(name: "Steam Again", executablePath: links[2].path),
            WindowsProgram(name: "Game Again", executablePath: urls[1].path),
            WindowsProgram(name: "Same Path", executablePath: links[0].path)
        ]
        try writeLegacyMetadata(bottle, store: store)
        let reopened = BottleStore(paths: paths)
        let loaded = try #require(try await reopened.list().first)
        #expect(loaded.programs == [first, game])
        let removed = try await reopened.removeProgram(id: first.id, in: bottle)
        #expect(removed.programs == [game])
        #expect(try await BottleStore(paths: paths).list().first?.programs == [game])
        let empty = try await reopened.removeProgram(id: game.id, in: bottle)
        #expect(empty.programs.isEmpty)
        #expect(try await BottleStore(paths: paths).list().first?.programs.isEmpty == true)
        for file in links + urls { #expect(FileManager.default.fileExists(atPath: file.path)) }
        let metadata = prefix.deletingLastPathComponent().appendingPathComponent("bottle.json")
        #expect(try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: metadata)).programs.isEmpty)
    }

    @Test func discoveryAndManualReadditionKeepDeterministicSurvivingLaunchers() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = try await store.create(name: "Discovered", runtime: runtime)
        let prefix = store.prefixURL(for: bottle)
        try writeFile(Data([0x4d, 0x5a]), to: prefix.appendingPathComponent("drive_c/Apps/Steam/steam.exe"))
        let drive = prefix.appendingPathComponent("drive_c")
        let menu = "ProgramData/Microsoft/Windows/Start Menu/Programs/"
        let linkPaths = [
            "users/player/Desktop/Desktop Steam.lnk",
            "users/player/AppData/Roaming/Microsoft/Windows/Start Menu/Programs/User Steam.lnk",
            menu + "Z Steam.lnk",
            menu + "A Steam.lnk"
        ]
        for path in linkPaths { try writeFile(shortcut(), to: drive.appendingPathComponent(path)) }
        let gamePaths = ["users/player/Desktop/Game.url", menu + "Game.url"]
        for path in gamePaths {
            try writeFile(internetShortcut("steam://rungameid/4369130"), to: drive.appendingPathComponent(path))
        }
        let discovered = try await store.discoverPrograms(in: bottle)
        #expect(discovered.programs.map { URL(fileURLWithPath: $0.executablePath).resolvingSymlinksInPath().path } == [
            drive.appendingPathComponent(menu + "A Steam.lnk").resolvingSymlinksInPath().path,
            drive.appendingPathComponent(menu + "Game.url").resolvingSymlinksInPath().path
        ])
        #expect(try await store.discoverPrograms(in: bottle).programs == discovered.programs)
        for path in linkPaths + gamePaths {
            let registered = try await store.registerProgram(in: bottle, executableURL: drive.appendingPathComponent(path),
                                                            name: "Replacement Name")
            #expect(registered.programs == discovered.programs)
        }
        #expect(try await BottleStore(paths: paths).list().first?.programs == discovered.programs)
    }

    @Test func manuallyRegisteredLauncherWinsOverDiscoveredAliasesAndEquivalentExecutable() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = try await store.create(name: "Manual", runtime: runtime)
        let prefix = store.prefixURL(for: bottle)
        let executable = prefix.appendingPathComponent("drive_c/Apps/Steam/steam.exe")
        try writeFile(Data([0x4d, 0x5a]), to: executable)
        let desktop = prefix.appendingPathComponent("drive_c/users/player/Desktop/Steam.lnk")
        let menu = prefix.appendingPathComponent("drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Steam.lnk")
        try writeFile(shortcut(), to: desktop)
        try writeFile(shortcut(arguments: ""), to: menu)
        let registered = try await store.registerProgram(in: bottle, executableURL: desktop, name: "My Launcher")
        #expect(registered.programs.count == 1)
        #expect(registered.programs.first?.executablePath == desktop.path)
        #expect(registered.programs.first?.name == "My Launcher")
        #expect(try await store.registerProgram(in: bottle, executableURL: menu).programs == registered.programs)
        #expect(try await store.registerProgram(in: bottle, executableURL: executable).programs == registered.programs)
        #expect(try await store.discoverPrograms(in: bottle).programs == registered.programs)
    }

    @Test func commandArgumentsWorkingDirectoryAndLaunchOptionsRemainDistinct() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = try await store.create(name: "Options", runtime: runtime)
        let prefix = store.prefixURL(for: bottle)
        for path in ["drive_c/Apps/Steam/steam.exe", "drive_c/Apps/Steam/other.exe", "drive_c/Other/placeholder"] {
            try writeFile(Data([0x4d, 0x5a]), to: prefix.appendingPathComponent(path))
        }
        let variants: [(String, Data)] = [
            ("Default", shortcut()),
            ("Game One", shortcut(arguments: "-applaunch 10")),
            ("Game Two", shortcut(arguments: "-applaunch 20")),
            ("Raw Spacing", shortcut(arguments: "-applaunch  10")),
            ("Working Directory", shortcut(working: "C:\\Other")),
            ("Maximized", shortcut(show: 3)),
            ("Administrator", shortcut(runAs: true)),
            ("Other Binary", shortcut(target: "C:\\Apps\\Steam\\other.exe"))
        ]
        var registered = bottle
        for (name, data) in variants {
            let file = paths.root.appendingPathComponent(name + ".lnk")
            try writeFile(data, to: file)
            registered = try await store.registerProgram(in: bottle, executableURL: file, name: "Steam")
        }
        #expect(registered.programs.count == variants.count)
        #expect(Set(registered.programs.map(\.executablePath)) == Set(variants.map { paths.root.appendingPathComponent($0.0 + ".lnk").path }))
        #expect(Set(registered.programs.map(\.name)) == ["Steam"])
        let alias = paths.root.appendingPathComponent("Alias.lnk")
        try writeFile(shortcut(arguments: "", icon: "C:\\Different.ico"), to: alias)
        #expect(try await store.registerProgram(in: bottle, executableURL: alias).programs == registered.programs)
        #expect(try await BottleStore(paths: paths).list().first?.programs == registered.programs)
    }

    @Test func internetShortcutIdentityPreservesGameIDsAndFullURLParameters() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = try await store.create(name: "URLs", runtime: runtime)
        let targets = [
            "steam://rungameid/10",
            "steam://rungameid/20",
            "https://example.invalid/play?id=10&mode=normal",
            "https://example.invalid/play?id=10&mode=safe"
        ]
        var registered = bottle
        for (index, target) in targets.enumerated() {
            let file = paths.root.appendingPathComponent("Game \(index).url")
            try writeFile(internetShortcut(target), to: file)
            registered = try await store.registerProgram(in: bottle, executableURL: file, name: "Game")
        }
        #expect(registered.programs.count == targets.count)
        for (index, target) in targets.enumerated() {
            let alias = paths.root.appendingPathComponent("Alias \(index).URL")
            try writeFile(internetShortcut(target, icon: "C:\\Different.ico"), to: alias)
            #expect(try await store.registerProgram(in: bottle, executableURL: alias).programs == registered.programs)
        }
    }

    @Test func unresolvedAndMalformedLaunchersOnlyCollapseDuplicatePaths() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var bottle = try await store.create(name: "Unresolved", runtime: runtime)
        let files: [(String, Data?)] = [
            ("Missing One.lnk", nil), ("Missing Two.lnk", nil),
            ("Malformed One.lnk", Data([1])), ("Malformed Two.lnk", Data([1])),
            ("Unresolved One.lnk", shortcut()), ("Unresolved Two.lnk", shortcut()),
            ("Unsupported One.txt", shortcut()), ("Unsupported Two.txt", shortcut()),
            ("Malformed One.url", Data("[InternetShortcut]\n".utf8)),
            ("Malformed Two.url", Data("[InternetShortcut]\n".utf8))
        ]
        for (name, data) in files {
            let url = paths.root.appendingPathComponent(name)
            if let data { try writeFile(data, to: url) }
            bottle.programs.append(WindowsProgram(name: "Same Name", executablePath: url.path))
        }
        let expected = bottle.programs
        bottle.programs += expected.map { WindowsProgram(name: "Duplicate", executablePath: $0.executablePath) }
        try writeLegacyMetadata(bottle, store: store)
        #expect(try await store.list().first?.programs == expected)
        // Saving also performs the cutover, without inventing new IDs or dropping unresolved paths.
        try await store.save(bottle)
        let metadata = store.prefixURL(for: bottle).deletingLastPathComponent().appendingPathComponent("bottle.json")
        #expect(try JSONDecoder().decode(Bottle.self, from: Data(contentsOf: metadata)).programs == expected)
        #expect(try await BottleStore(paths: paths).list().first?.programs == expected)
    }

    @Test func alteredBottleIdentityIsRejectedInsteadOfOverwritingMetadata() async throws {
        let (paths, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let bottle = try await store.create(name: "Safe", runtime: runtime)
        let directory = store.prefixURL(for: bottle).deletingLastPathComponent()
        let replacement = Bottle(name: "Foreign", runtime: runtime)
        let encoder = JSONEncoder()
        try encoder.encode(replacement).write(to: directory.appendingPathComponent("bottle.json"))
        await #expect(throws: MagicWineError.self) { try await store.save(bottle) }
        let data = try Data(contentsOf: directory.appendingPathComponent("bottle.json"))
        let decoder = JSONDecoder()
        #expect(try decoder.decode(Bottle.self, from: data).id == replacement.id)
    }
}
