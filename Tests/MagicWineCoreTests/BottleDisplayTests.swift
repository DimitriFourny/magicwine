import Foundation
import Testing
@testable import MagicWineCore

struct BottleDisplayTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var prefix: URL { root.appendingPathComponent("prefix") }
        var user: URL { prefix.appendingPathComponent("user.reg") }
        var system: URL { prefix.appendingPathComponent("system.reg") }

        init() throws {
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        }

        func write(_ body: String, to url: URL? = nil) throws {
            try Data(("WINE REGISTRY Version 2\n\n" + body).utf8).write(to: url ?? user)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test(arguments: ["n", "y"])
    func migrationPreservesExplicitRetinaAndImplicitWineDPI(retina: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("[Software\\\\Wine\\\\Mac Driver]\n\"RetinaMode\"=\"\(retina)\"\n")
        let migrated = try #require(try BottleDisplay.existingConfiguration(prefix: fixture.prefix))
        #expect(migrated.retinaEnabled == (retina == "y"))
        #expect(migrated.dpi == 96)
        try BottleDisplay.apply(migrated, prefix: fixture.prefix)
        #expect(try BottleDisplay.existingConfiguration(prefix: fixture.prefix) == migrated)
    }

    @Test(arguments: [false, true])
    func migrationPreservesCustomDPIFromEitherHive(systemFallback: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let section = systemFallback ? "System\\\\ControlSet001\\\\Hardware Profiles\\\\Current\\\\Software\\\\Fonts" : "Control Panel\\\\Desktop"
        try fixture.write("[\(section)]\n\"LogPixels\"=dword:00000090\n",
                          to: systemFallback ? fixture.system : fixture.user)
        let migrated = try #require(try BottleDisplay.existingConfiguration(prefix: fixture.prefix))
        #expect(!migrated.retinaEnabled)
        #expect(migrated.dpi == 144)
        let systemBefore = systemFallback ? try Data(contentsOf: fixture.system) : nil
        try BottleDisplay.apply(migrated, prefix: fixture.prefix)
        #expect(try BottleDisplay.existingConfiguration(prefix: fixture.prefix) == migrated)
        if let systemBefore { #expect(try Data(contentsOf: fixture.system) == systemBefore) }
    }

    @Test func userDPIOverridesSystemFallback() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("[Control Panel\\\\Desktop]\n\"LogPixels\"=dword:00000078\n")
        try fixture.write("[System\\\\ControlSet001\\\\Hardware Profiles\\\\Current\\\\Software\\\\Fonts]\n\"LogPixels\"=dword:00000090\n", to: fixture.system)
        #expect(try BottleDisplay.existingConfiguration(prefix: fixture.prefix)?.dpi == 120)
    }

    @Test(arguments: ["absent", "user", "system"])
    func uncustomizedLegacyPrefixMigratesToRetina192(source: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        if source == "user" {
            try fixture.write("[Control Panel\\\\Desktop]\n\"LogPixels\"=dword:00000060\n")
        } else if source == "system" {
            try fixture.write("[System\\\\ControlSet001\\\\Hardware Profiles\\\\Current\\\\Software\\\\Fonts]\n\"LogPixels\"=dword:00000060\n", to: fixture.system)
        }
        let legacy = try BottleDisplay.existingConfiguration(prefix: fixture.prefix)
        #expect(legacy == nil)
        let migrated = legacy ?? DisplayConfiguration()
        try BottleDisplay.apply(migrated, prefix: fixture.prefix)
        let persisted = try #require(try BottleDisplay.existingConfiguration(prefix: fixture.prefix))
        #expect(persisted.retinaEnabled)
        #expect(persisted.dpi == 192)
        #expect(try !BottleDisplay.needsUpdate(migrated, prefix: fixture.prefix))
    }

    @Test func togglesPersistAndPreserveUnrelatedCRLFRegistryBytes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unrelated = "[Unrelated\\\\Settings] 123\r\n#time=123\r\n\"RetinaMode\"=\"leave alone\"\r\n\"Binary\"=hex:01,ab,ff\r\n"
        let desktop = "[Control Panel\\\\Desktop] 456\r\n\"Wallpaper\"=\"keep.bmp\"\r\n"
        try Data(("WINE REGISTRY Version 2\r\n\r\n" + unrelated + "\r\n" + desktop).utf8).write(to: fixture.user)
        for enabled in [true, false] {
            let desired = DisplayConfiguration(retinaEnabled: enabled)
            #expect(try BottleDisplay.needsUpdate(desired, prefix: fixture.prefix))
            try BottleDisplay.apply(desired, prefix: fixture.prefix)
            #expect(try BottleDisplay.existingConfiguration(prefix: fixture.prefix) == desired)
            let text = try String(contentsOf: fixture.user, encoding: .utf8)
            #expect(text.contains(unrelated))
            #expect(text.contains("\"Wallpaper\"=\"keep.bmp\"\r\n"))
            #expect(!text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        }
    }

    @Test func wineCanonicalizationDoesNotRequireRewrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("[software\\\\wine\\\\mac driver]\n\"retinamode\"=\"Yes\"\n\n[CONTROL PANEL\\\\DESKTOP]\n\"LOGPIXELS\"=DWORD:000000C0\n")
        let original = try Data(contentsOf: fixture.user)
        #expect(try !BottleDisplay.needsUpdate(.init(), prefix: fixture.prefix))
        try BottleDisplay.apply(.init(), prefix: fixture.prefix)
        #expect(try Data(contentsOf: fixture.user) == original)
    }

    @Test(arguments: [
        "[Software\\\\Wine\\\\Mac Driver]\n\"RetinaMode\"=dword:00000001\n",
        "[Software\\\\Wine\\\\Mac Driver]\n\"RetinaMode\"=\"unknown\"\n",
        "[Control Panel\\\\Desktop]\n\"LogPixels\"=\"144\"\n",
        "[Control Panel\\\\Desktop]\n\"LogPixels\"=dword:xyz\n",
        "[Control Panel\\\\Desktop]\n\"LogPixels\"=dword:100000000\n",
        "[Control Panel\\\\Desktop]\n\"LogPixels\" dword:00000090\n"
    ])
    func malformedSettingsFailWithoutModification(body: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(body)
        let original = try Data(contentsOf: fixture.user)
        #expect(throws: (any Error).self) { try BottleDisplay.existingConfiguration(prefix: fixture.prefix) }
        #expect(throws: (any Error).self) { try BottleDisplay.needsUpdate(.init(), prefix: fixture.prefix) }
        #expect(throws: (any Error).self) { try BottleDisplay.apply(.init(), prefix: fixture.prefix) }
        #expect(try Data(contentsOf: fixture.user) == original)
    }

    @Test func malformedSystemFallbackIsNotDiscardedDuringMigration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("[System\\\\ControlSet001\\\\Hardware Profiles\\\\Current\\\\Software\\\\Fonts]\n\"LogPixels\"=\"custom\"\n", to: fixture.system)
        let original = try Data(contentsOf: fixture.system)
        #expect(throws: (any Error).self) { try BottleDisplay.existingConfiguration(prefix: fixture.prefix) }
        #expect(try Data(contentsOf: fixture.system) == original)
        #expect(!FileManager.default.fileExists(atPath: fixture.user.path))
    }

    @Test(arguments: ["user.reg", "system.reg", "prefix"])
    func rejectsSymbolicLinksWithoutTouchingTargets(target: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let host = fixture.root.appendingPathComponent("host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false)
        let sentinel = host.appendingPathComponent("user.reg")
        let content = Data("WINE REGISTRY Version 2\n\n".utf8)
        try content.write(to: sentinel)
        let link = target == "prefix" ? fixture.prefix : fixture.prefix.appendingPathComponent(target)
        if target == "prefix" { try FileManager.default.removeItem(at: fixture.prefix) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target == "prefix" ? host : sentinel)
        #expect(throws: (any Error).self) { try BottleDisplay.existingConfiguration(prefix: fixture.prefix) }
        if target != "system.reg" {
            #expect(throws: (any Error).self) { try BottleDisplay.needsUpdate(.init(), prefix: fixture.prefix) }
            #expect(throws: (any Error).self) { try BottleDisplay.apply(.init(), prefix: fixture.prefix) }
        }
        #expect(try Data(contentsOf: sentinel) == content)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == (target == "prefix" ? host.path : sentinel.path))
    }
}
