import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct RosettaCPUCompatibilityTests {
    private struct Fixture {
        static let original = Data("fixture Wine 11 original CPU".utf8)
        static let native = Data("fixture native Rosetta CPU".utf8)
        static let source = Data("fixture corresponding source archive".utf8)
        static let license = Data("fixture Wine LGPL notice".utf8)
        let directory: URL
        let bottle: URL
        let prefix: URL
        let destination: URL
        let resources: URL
        let payload: RosettaCPUCompatibility.Payload

        var compatibility: URL { bottle.appendingPathComponent("runtime-compatibility", isDirectory: true) }
        var backup: URL { compatibility.appendingPathComponent(RosettaCPUCompatibility.componentID, isDirectory: true) }
        var originalBackup: URL { backup.appendingPathComponent(RosettaCPUCompatibility.originalName) }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            bottle = directory.appendingPathComponent("Managed/Bottles/fixture", isDirectory: true)
            prefix = bottle.appendingPathComponent("prefix", isDirectory: true)
            destination = prefix.appendingPathComponent("drive_c/windows/system32/wow64cpu.dll")
            resources = directory.appendingPathComponent("Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
            let dll = resources.appendingPathComponent(RosettaCPUCompatibility.componentID + ".dll")
            let source = resources.appendingPathComponent(RosettaCPUCompatibility.sourceName)
            let license = resources.appendingPathComponent(RosettaCPUCompatibility.licenseName)
            try Self.original.write(to: destination)
            try Self.native.write(to: dll)
            try Self.source.write(to: source)
            try Self.license.write(to: license)
            payload = RosettaCPUCompatibility.Payload(dll: dll, source: source, license: license,
                dllSHA256: RosettaCPUCompatibilityTests.digest(Self.native),
                sourceSHA256: RosettaCPUCompatibilityTests.digest(Self.source),
                licenseSHA256: RosettaCPUCompatibilityTests.digest(Self.license))
        }

        @discardableResult
        func install(prefix prefixOverride: URL? = nil) throws -> Bool {
            try RosettaCPUCompatibility.install(prefix: prefixOverride ?? prefix, bottleDirectory: bottle,
                payload: payload, originalSHA256: RosettaCPUCompatibilityTests.digest(Self.original))
        }

        func resource(_ kind: String) -> URL {
            switch kind {
            case "dll": payload.dll
            case "source": payload.source
            default: payload.license
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: directory) }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func inode(_ url: URL) throws -> UInt64 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        return status.st_ino
    }

    @Test func preservesOriginalAndLicensingWithAtomicRepeatableReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let originalInode = try inode(fixture.destination)
        let openOriginal = try FileHandle(forReadingFrom: fixture.destination)
        defer { try? openOriginal.close() }
        #expect(try fixture.install())
        #expect(try Data(contentsOf: fixture.destination) == Fixture.native)
        #expect(try openOriginal.readToEnd() == Fixture.original)
        #expect(try Data(contentsOf: fixture.originalBackup) == Fixture.original)
        #expect(try Data(contentsOf: fixture.backup.appendingPathComponent(RosettaCPUCompatibility.sourceName)) == Fixture.source)
        #expect(try Data(contentsOf: fixture.backup.appendingPathComponent(RosettaCPUCompatibility.licenseName)) == Fixture.license)
        let installedInode = try inode(fixture.destination)
        let backupInode = try inode(fixture.originalBackup)
        #expect(installedInode != originalInode)
        #expect(backupInode != originalInode)
        #expect(try fixture.install())
        #expect(try inode(fixture.destination) == installedInode)
        #expect(try inode(fixture.originalBackup) == backupInode)
        #expect(try Data(contentsOf: fixture.payload.dll) == Fixture.native)
    }

    @Test func resumesFromCompleteBackupWithoutRecapturingOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.install()
        let backupInode = try inode(fixture.originalBackup)
        // Models an interrupted installation after backup publication but before
        // the single DLL rename, or Wine having restored its exact stock DLL.
        try Fixture.original.write(to: fixture.destination, options: .atomic)
        #expect(try fixture.install())
        #expect(try Data(contentsOf: fixture.destination) == Fixture.native)
        #expect(try inode(fixture.originalBackup) == backupInode)
        #expect(try Data(contentsOf: fixture.originalBackup) == Fixture.original)
    }

    @Test(arguments: ["dll", "source", "license"], ["corrupt", "missing", "symlink", "hardlink"])
    func rejectsUntrustedResourcesBeforeCreatingBackup(kind: String, fault: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target = fixture.resource(kind)
        let expected = try Data(contentsOf: target)
        let external = fixture.directory.appendingPathComponent("External")
        switch fault {
        case "corrupt": try Data("changed resource".utf8).write(to: target)
        case "missing": try FileManager.default.removeItem(at: target)
        case "symlink":
            try expected.write(to: external)
            try FileManager.default.removeItem(at: target)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
        default: try FileManager.default.linkItem(at: target, to: external)
        }
        #expect(throws: (any Error).self) { try fixture.install() }
        #expect(try Data(contentsOf: fixture.destination) == Fixture.original)
        #expect(!FileManager.default.fileExists(atPath: fixture.compatibility.path))
        if fault == "symlink" || fault == "hardlink" {
            #expect(try Data(contentsOf: external) == expected)
        }
    }

    @Test(arguments: [false, true])
    func refusesCustomDLLWithoutOverwritingIt(hasBackup: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        if hasBackup { try fixture.install() }
        let custom = Data("user-supplied custom CPU".utf8)
        try custom.write(to: fixture.destination, options: .atomic)
        let customInode = try inode(fixture.destination)
        #expect(throws: MagicWineError.self) { try fixture.install() }
        #expect(try Data(contentsOf: fixture.destination) == custom)
        #expect(try inode(fixture.destination) == customInode)
        if hasBackup { #expect(try Data(contentsOf: fixture.originalBackup) == Fixture.original) }
        else { #expect(!FileManager.default.fileExists(atPath: fixture.compatibility.path)) }
    }

    @Test(arguments: ["missing", "symlink", "hardlink", "directory"])
    func refusesUnownedPrefixDLL(fault: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let external = fixture.directory.appendingPathComponent("External.dll")
        try Fixture.original.write(to: external)
        try FileManager.default.removeItem(at: fixture.destination)
        switch fault {
        case "symlink": try FileManager.default.createSymbolicLink(at: fixture.destination, withDestinationURL: external)
        case "hardlink": try FileManager.default.linkItem(at: external, to: fixture.destination)
        case "directory": try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: false)
        default: break
        }
        #expect(throws: (any Error).self) { try fixture.install() }
        #expect(try Data(contentsOf: external) == Fixture.original)
        #expect(!FileManager.default.fileExists(atPath: fixture.compatibility.path))
    }

    @Test(arguments: ["managed", "bottles", "bottle", "prefix", "drive_c", "windows", "system32", "resources", "compatibility", "backup"])
    func rejectsSymlinkedDirectoriesWithoutChangingTheirContents(location: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let target: URL
        switch location {
        case "managed": target = fixture.bottle.deletingLastPathComponent().deletingLastPathComponent()
        case "bottles": target = fixture.bottle.deletingLastPathComponent()
        case "bottle": target = fixture.bottle
        case "prefix": target = fixture.prefix
        case "drive_c": target = fixture.prefix.appendingPathComponent("drive_c")
        case "windows": target = fixture.prefix.appendingPathComponent("drive_c/windows")
        case "system32": target = fixture.destination.deletingLastPathComponent()
        case "resources": target = fixture.resources
        case "compatibility":
            try fixture.install()
            target = fixture.compatibility
        default:
            try fixture.install()
            target = fixture.backup
        }
        let external = fixture.directory.appendingPathComponent("ExternalDirectory", isDirectory: true)
        try FileManager.default.moveItem(at: target, to: external)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
        let marker = external.appendingPathComponent("custom-marker")
        let custom = Data("keep external contents".utf8)
        try custom.write(to: marker)
        #expect(throws: MagicWineError.self) { try fixture.install() }
        #expect(try Data(contentsOf: marker) == custom)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == external.path)
        #expect(try Data(contentsOf: fixture.destination) == (location == "compatibility" || location == "backup" ? Fixture.native : Fixture.original))
    }

    @Test func rejectsPrefixOutsideBottle() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let outside = fixture.directory.appendingPathComponent("OutsidePrefix", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.prefix, to: outside)
        #expect(throws: MagicWineError.self) { try fixture.install(prefix: outside) }
        #expect(try Data(contentsOf: outside.appendingPathComponent("drive_c/windows/system32/wow64cpu.dll")) == Fixture.original)
        #expect(!FileManager.default.fileExists(atPath: fixture.compatibility.path))
    }

    @Test(arguments: [RosettaCPUCompatibility.originalName, RosettaCPUCompatibility.sourceName, RosettaCPUCompatibility.licenseName],
          ["missing", "corrupt", "symlink", "hardlink"])
    func refusesDamagedBackupsInsteadOfRepairingOrBlessingThem(name: String, fault: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.install()
        let installedInode = try inode(fixture.destination)
        let target = fixture.backup.appendingPathComponent(name)
        let saved = try Data(contentsOf: target)
        let external = fixture.directory.appendingPathComponent("ExternalBackup")
        switch fault {
        case "missing": try FileManager.default.removeItem(at: target)
        case "corrupt": try Data("corrupt backup".utf8).write(to: target)
        case "symlink":
            try FileManager.default.moveItem(at: target, to: external)
            try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
        default: try FileManager.default.linkItem(at: target, to: external)
        }
        #expect(throws: MagicWineError.self) { try fixture.install() }
        #expect(try Data(contentsOf: fixture.destination) == Fixture.native)
        #expect(try inode(fixture.destination) == installedInode)
        if fault == "missing" { #expect(!FileManager.default.fileExists(atPath: target.path)) }
        if fault == "corrupt" { #expect(try Data(contentsOf: target) == Data("corrupt backup".utf8)) }
        if fault == "symlink" || fault == "hardlink" { #expect(try Data(contentsOf: external) == saved) }
    }

    @Test(arguments: [false, true])
    func neverAdoptsManagedDLLWithoutOriginalBackup(removeWholeDirectory: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.install()
        try FileManager.default.removeItem(at: removeWholeDirectory ? fixture.backup : fixture.originalBackup)
        #expect(throws: MagicWineError.self) { try fixture.install() }
        #expect(try Data(contentsOf: fixture.destination) == Fixture.native)
        #expect(!FileManager.default.fileExists(atPath: fixture.originalBackup.path))
    }

    @Test func preservesIncompleteAndCustomBackupContentsWithStockDLL() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.backup, withIntermediateDirectories: true)
        let custom = fixture.backup.appendingPathComponent("custom.dat")
        let bytes = Data("user-owned backup contents".utf8)
        try bytes.write(to: custom)
        #expect(throws: MagicWineError.self) { try fixture.install() }
        #expect(try Data(contentsOf: custom) == bytes)
        #expect(try Data(contentsOf: fixture.destination) == Fixture.original)
        #expect(!FileManager.default.fileExists(atPath: fixture.originalBackup.path))
    }

    @Test func forgedReceiptCannotAuthorizeChangedOriginal() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.install()
        let changed = Data("forged original".utf8)
        try changed.write(to: fixture.originalBackup)
        let receipt = fixture.backup.appendingPathComponent("installation.json")
        try JSONSerialization.data(withJSONObject: ["originalSHA256": Self.digest(changed),
            "dllSHA256": fixture.payload.dllSHA256]).write(to: receipt)
        #expect(throws: MagicWineError.self) { try fixture.install() }
        #expect(try Data(contentsOf: fixture.originalBackup) == changed)
        #expect(try Data(contentsOf: fixture.destination) == Fixture.native)
    }

    @Test(arguments: ["wine-10.0", "wine-11.0", "wine-11.0 (custom build)"])
    func unknownRuntimeIsUnchangedAndDoesNotInstall(version: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let runtimeRoot = fixture.directory.appendingPathComponent("Wine", isDirectory: true)
        let executable = runtimeRoot.appendingPathComponent("bin/wine")
        let cpu = runtimeRoot.appendingPathComponent("lib/wine/x86_64-windows/wow64cpu.dll")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cpu.deletingLastPathComponent(), withIntermediateDirectories: true)
        let customRuntime = Data("unknown runtime ABI".utf8)
        try customRuntime.write(to: cpu)
        let runtime = RuntimeDescriptor(executableURL: executable, version: version)
        #expect(try !RosettaCPUCompatibility.prepare(runtime: runtime, prefix: fixture.prefix, bottleDirectory: fixture.bottle))
        #expect(try Data(contentsOf: cpu) == customRuntime)
        #expect(try Data(contentsOf: fixture.destination) == Fixture.original)
        #expect(!FileManager.default.fileExists(atPath: fixture.compatibility.path))
    }
}
