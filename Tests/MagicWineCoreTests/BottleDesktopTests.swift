import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct BottleDesktopTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var prefix: URL { root.appendingPathComponent("prefix") }
        var users: URL { prefix.appendingPathComponent("drive_c/users") }
        var host: URL { root.appendingPathComponent("host/Desktop") }

        init() throws {
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        }

        func profile(_ name: String) throws -> URL {
            let profile = users.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            return profile
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func fileType(_ url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        return status.st_mode & mode_t(S_IFMT)
    }

    @Test func freshPrefixPrecreatesCurrentWineUserDesktop() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let name = try BottleDesktop.userName(environment: ProcessInfo.processInfo.environment)
        let desktop = fixture.users.appendingPathComponent(name).appendingPathComponent("Desktop")

        try BottleDesktop.prepare(prefix: fixture.prefix)

        #expect(try fileType(desktop) == mode_t(S_IFDIR))
        #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.users.appendingPathComponent(name + "/Documents").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.host.path).isEmpty)
    }

    @Test func migratesEveryProfileWithoutTouchingHostDataOrOtherMappings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = Data("host shortcut and personal data".utf8)
        let hostFile = fixture.host.appendingPathComponent("keep.url")
        try original.write(to: hostFile)
        let nested = fixture.host.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        try original.write(to: nested.appendingPathComponent("keep.txt"))
        let profiles = try [fixture.profile("first-user"), fixture.profile("second-user")]
        for profile in profiles {
            try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("Desktop"), withDestinationURL: fixture.host)
            try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("Documents"), withDestinationURL: fixture.host)
        }

        try BottleDesktop.prepare(prefix: fixture.prefix)

        for profile in profiles {
            let desktop = profile.appendingPathComponent("Desktop")
            #expect(try fileType(desktop) == mode_t(S_IFDIR))
            #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path).isEmpty)
            #expect(try fileType(profile.appendingPathComponent("Documents")) == mode_t(S_IFLNK))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: profile.appendingPathComponent("Documents").path) == fixture.host.path)
        }
        #expect(try Data(contentsOf: hostFile) == original)
        #expect(try Data(contentsOf: nested.appendingPathComponent("keep.txt")) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.host.path).sorted() == ["keep.url", "nested"])
    }

    @Test func preservesExistingLocalDesktopContentsOnRepeatedPreparation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let desktop = try fixture.profile("local-user").appendingPathComponent("Desktop")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: false)
        let content = Data("local shortcut".utf8)
        let shortcut = desktop.appendingPathComponent("Game.url")
        try content.write(to: shortcut)
        let hostLink = desktop.appendingPathComponent("unrelated-link")
        try FileManager.default.createSymbolicLink(at: hostLink, withDestinationURL: fixture.host)

        try BottleDesktop.prepare(prefix: fixture.prefix)
        try BottleDesktop.prepare(prefix: fixture.prefix)

        #expect(try fileType(desktop) == mode_t(S_IFDIR))
        #expect(try Data(contentsOf: shortcut) == content)
        #expect(try fileType(hostLink) == mode_t(S_IFLNK))
        #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path).sorted() == ["Game.url", "unrelated-link"])
    }

    @Test func replacesBrokenDesktopLinkWithoutCreatingTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let desktop = try fixture.profile("broken-user").appendingPathComponent("Desktop")
        let missingTarget = fixture.root.appendingPathComponent("missing/Desktop")
        try FileManager.default.createSymbolicLink(at: desktop, withDestinationURL: missingTarget)

        try BottleDesktop.prepare(prefix: fixture.prefix)

        #expect(try fileType(desktop) == mode_t(S_IFDIR))
        #expect(try FileManager.default.contentsOfDirectory(atPath: desktop.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missingTarget.deletingLastPathComponent().path))
    }

    @Test(arguments: ["prefix", "prefix/drive_c", "prefix/drive_c/users", "prefix/drive_c/users/linked-user"])
    func rejectsLinkedParentsWithoutTouchingTheirTargets(path: String) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sentinel = fixture.host.appendingPathComponent("keep.txt")
        let content = Data("do not modify".utf8)
        try content.write(to: sentinel)
        let parent = fixture.root.appendingPathComponent(path)
        if path == "prefix" { try FileManager.default.removeItem(at: fixture.prefix) }
        try FileManager.default.createDirectory(at: parent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: fixture.host)

        #expect(throws: (any Error).self) { try BottleDesktop.prepare(prefix: fixture.prefix) }

        #expect(try fileType(parent) == mode_t(S_IFLNK))
        #expect(try Data(contentsOf: sentinel) == content)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.host.path) == ["keep.txt"])
    }

    @Test func preservesRegularFileAtDesktopAndReportsFailure() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let desktop = try fixture.profile("file-user").appendingPathComponent("Desktop")
        let content = Data("not a directory".utf8)
        try content.write(to: desktop)

        #expect(throws: (any Error).self) { try BottleDesktop.prepare(prefix: fixture.prefix) }

        #expect(try fileType(desktop) == mode_t(S_IFREG))
        #expect(try Data(contentsOf: desktop) == content)
    }

    @Test func usesWineUsernameSelectionWithoutChangingProcessEnvironment() throws {
        #expect(try BottleDesktop.userName(environment: ["USER": "test-user"]) == "test-user")
        #expect(try BottleDesktop.userName(environment: ["USER": "unix/path/domain\\test-user"]) == "test-user")
        #expect(try BottleDesktop.userName(environment: ["USER": "test-user", "WINEUSERNAME": "ignored"]) == "test-user")
        #expect(try BottleDesktop.userName(environment: [:]) == NSUserName())
    }

    @Test(arguments: ["", ".", "..", "user/", "domain\\", "domain\\..", "bad\0name"])
    func rejectsUnsafeWineUsernames(name: String) {
        #expect(throws: (any Error).self) { try BottleDesktop.userName(environment: ["USER": name]) }
    }
}
