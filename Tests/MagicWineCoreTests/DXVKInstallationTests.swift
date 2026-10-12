import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct DXVKInstallationTests {
    private struct Fixture {
        let directory: URL
        let paths: ApplicationPaths
        let component: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            paths = ApplicationPaths(root: directory.appendingPathComponent("Managed", isDirectory: true))
            component = paths.componentsDirectory.appendingPathComponent(DXVKInstallation.componentID, isDirectory: true)
            try paths.prepare()
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private let metadataNames = ["LICENSE-DXVK.txt", "LICENSE-DXVK-macOS.txt", "LICENSE-DXVK-DEPENDENCIES.txt", "PROVENANCE.txt"]
    private let dllPaths = ["x32/d3d10core.dll", "x32/d3d11.dll", "x64/d3d10core.dll", "x64/d3d11.dll"]

    // Small structurally valid PE images exercise validation without networking or
    // redistributing megabytes of third-party DLLs as test fixtures. They are not
    // the pinned package and must never pass component checksum validation.
    private func pe(machine: UInt16) -> Data {
        var bytes = Data(repeating: 0, count: 256)
        bytes[0] = 0x4d
        bytes[1] = 0x5a
        bytes[60] = 0x80
        bytes[128] = 0x50
        bytes[129] = 0x45
        bytes[132] = UInt8(truncatingIfNeeded: machine)
        bytes[133] = UInt8(truncatingIfNeeded: machine >> 8)
        bytes[148] = 0x60 // SizeOfOptionalHeader
        bytes[151] = 0x20 // IMAGE_FILE_DLL
        bytes[152] = 0x0b
        bytes[153] = machine == 0x014c ? 0x01 : 0x02
        return bytes
    }

    private func makePayload(at root: URL, metadata: Bool = false) throws {
        for name in ["x32", "x64"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
            for dll in ["d3d10core.dll", "d3d11.dll"] {
                try pe(machine: name == "x32" ? 0x014c : 0x8664).write(to: root.appendingPathComponent("\(name)/\(dll)"))
            }
        }
        try Data("# preserved package config\n".utf8).write(to: root.appendingPathComponent("dxvk.conf"))
        if metadata {
            for name in metadataNames { try Data("attribution test content\n".utf8).write(to: root.appendingPathComponent(name)) }
            try DXVKInstallation.writeReceipt(at: root)
        }
    }

    private func archiveEntries() -> [String] {
        let root = DXVKInstallation.archiveRoot
        return [root + "/", root + "/dxvk.conf", root + "/x64/", root + "/x32/"]
            + dllPaths.map { root + "/" + $0 }
    }

    private func archiveTypes() -> [Character] { ["d", "-", "d", "d", "-", "-", "-", "-"] }

    @Test func acceptsOnlyCompleteNativeArchiveLayout() throws {
        try DXVKInstallation.validateArchiveMembers(archiveEntries(), types: archiveTypes())
        try DXVKInstallation.validateArchiveMembers(archiveEntries().map {
            $0.hasSuffix("/") ? String($0.dropLast()) : $0
        }, types: archiveTypes())
    }

    @Test(arguments: ["/etc/passwd", "../outside", "x32/../../outside", "x32\\d3d11.dll",
                       "x64/dxgi.dll", "x32/d3d9.dll", "x64/d3d11.dll/", "./x64/d3d11.dll"])
    func rejectsUnsafeOrUnexpectedArchivePaths(path: String) throws {
        var entries = archiveEntries()
        entries[7] = DXVKInstallation.archiveRoot + "/" + path
        // An absolute path must stay absolute to exercise that boundary as well.
        if path.hasPrefix("/") { entries[7] = path }
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validateArchiveMembers(entries, types: archiveTypes())
        }
    }

    @Test func rejectsDuplicateMissingAndExtraArchiveMembers() throws {
        let entries = archiveEntries()
        var duplicate = entries
        duplicate[7] = duplicate[6]
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validateArchiveMembers(duplicate, types: archiveTypes())
        }
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validateArchiveMembers(Array(entries.dropLast()), types: Array(archiveTypes().dropLast()))
        }
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validateArchiveMembers(entries + [entries[7]], types: archiveTypes() + ["-"])
        }
    }

    @Test(arguments: [Character("l"), Character("h"), Character("b"), Character("p"), Character("d")])
    func rejectsArchiveLinksAndSpecialFiles(type: Character) throws {
        var types = archiveTypes()
        types[7] = type
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validateArchiveMembers(archiveEntries(), types: types)
        }
    }

    @Test func nativePayloadRequiresBothArchitecturesAndCorrectMachines() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makePayload(at: fixture.component)
        try DXVKInstallation.validatePayloadLayout(at: fixture.component)
        let x64 = fixture.component.appendingPathComponent("x64/d3d11.dll")
        try pe(machine: 0x014c).write(to: x64)
        #expect(throws: MagicWineError.self) { try DXVKInstallation.validatePayloadLayout(at: fixture.component) }
        try pe(machine: 0x8664).write(to: x64)
        try FileManager.default.removeItem(at: fixture.component.appendingPathComponent("x32/d3d10core.dll"))
        #expect(throws: MagicWineError.self) { try DXVKInstallation.validatePayloadLayout(at: fixture.component) }
    }

    @Test(arguments: ["dos", "offset", "signature", "dll", "optional", "truncated", "arm64"])
    func rejectsInvalidPEImages(fault: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makePayload(at: fixture.component)
        let target = fixture.component.appendingPathComponent("x64/d3d11.dll")
        var bytes = pe(machine: 0x8664)
        switch fault {
        case "dos": bytes[0] = 0
        case "offset": bytes[63] = 0xff
        case "signature": bytes[128] = 0
        case "dll": bytes[151] = 0
        case "optional": bytes[153] = 0x01
        case "truncated": bytes = Data(bytes.prefix(150))
        case "arm64": bytes[132] = 0x64; bytes[133] = 0xaa
        default: Issue.record("Unknown fixture fault")
        }
        try bytes.write(to: target)
        #expect(throws: MagicWineError.self) { try DXVKInstallation.validatePayloadLayout(at: fixture.component) }
    }

    @Test(arguments: ["x32", "x64/d3d11.dll", "installation.json"])
    func rejectsEscapingSymlinksWithoutTouchingTheirTargets(path: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makePayload(at: fixture.component, metadata: true)
        let external = fixture.directory.appendingPathComponent("External")
        let original = Data("external content must remain unchanged".utf8)
        try original.write(to: external)
        let target = fixture.component.appendingPathComponent(path)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validate(componentID: DXVKInstallation.componentID, paths: fixture.paths)
        }
        #expect(try Data(contentsOf: external) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == external.path)
    }

    @Test func rejectsHardLinkedDLLsAndUnexpectedFiles() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makePayload(at: fixture.component)
        let target = fixture.component.appendingPathComponent("x64/d3d11.dll")
        let external = fixture.directory.appendingPathComponent("External.dll")
        try FileManager.default.linkItem(at: target, to: external)
        #expect(throws: MagicWineError.self) { try DXVKInstallation.validatePayloadLayout(at: fixture.component) }
        try FileManager.default.removeItem(at: external)
        try Data([1]).write(to: fixture.component.appendingPathComponent("x64/dxgi.dll"))
        #expect(throws: MagicWineError.self) { try DXVKInstallation.validatePayloadLayout(at: fixture.component) }
    }

    @Test(arguments: ["../escape", "/absolute", "dxvk-macos-other-version", "", "x32/d3d11.dll",
                       "dxvk-macos-1.10.3-20230507-repack-acd1520ad105"])
    func immutableLookupRejectsNonPinnedComponentIDs(id: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        #expect(throws: MagicWineError.self) { try DXVKInstallation.validate(componentID: id, paths: fixture.paths) }
    }

    @Test(arguments: ["component", "components", "root"])
    func rejectsSymlinkedManagedDirectories(location: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let external = fixture.directory.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        let target: URL
        switch location {
        case "component": target = fixture.component
        case "components": target = fixture.paths.componentsDirectory
        default: target = fixture.paths.root
        }
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validate(componentID: DXVKInstallation.componentID, paths: fixture.paths)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
    }

    @Test(arguments: ["source", "archiveSHA256", "componentID", "version", "repository", "upstreamLicenseSource", "forkLicenseSource", "files", "malformed"])
    func cachedReceiptMustMatchImmutableProvenance(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makePayload(at: fixture.component, metadata: true)
        let receipt = fixture.component.appendingPathComponent("installation.json")
        if field == "malformed" { try Data("not JSON".utf8).write(to: receipt) }
        else {
            var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
            if field == "files" { object[field] = ["x64/d3d11.dll": "wrong"] }
            else { object[field] = "changed" }
            try JSONSerialization.data(withJSONObject: object).write(to: receipt)
        }
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validate(componentID: DXVKInstallation.componentID, paths: fixture.paths)
        }
    }

    @Test func matchingReceiptCannotBlessDifferentNativeBinaries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makePayload(at: fixture.component, metadata: true)
        try DXVKInstallation.validatePayloadLayout(at: fixture.component, includesMetadata: true)
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validate(componentID: DXVKInstallation.componentID, paths: fixture.paths)
        }
        // Even a receipt altered to match every replacement file's digest cannot
        // change the independently curated per-file checksum pins.
        let receipt = fixture.component.appendingPathComponent("installation.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
        var files = try #require(object["files"] as? [String: String])
        for name in files.keys {
            files[name] = SHA256.hash(data: try Data(contentsOf: fixture.component.appendingPathComponent(name)))
                .map { String(format: "%02x", $0) }.joined()
        }
        object["files"] = files
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validate(componentID: DXVKInstallation.componentID, paths: fixture.paths)
        }
    }

    @Test(arguments: ["x32/d3d10core.dll", "x32/d3d11.dll", "x64/d3d10core.dll", "x64/d3d11.dll",
                       "dxvk.conf", "installation.json", "LICENSE-DXVK.txt", "LICENSE-DXVK-macOS.txt",
                       "LICENSE-DXVK-DEPENDENCIES.txt", "PROVENANCE.txt"])
    func incompleteManagedPackageIsNeverAdopted(path: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makePayload(at: fixture.component, metadata: true)
        try FileManager.default.removeItem(at: fixture.component.appendingPathComponent(path))
        #expect(throws: MagicWineError.self) {
            try DXVKInstallation.validate(componentID: DXVKInstallation.componentID, paths: fixture.paths)
        }
    }

    @Test func installationRejectsUnsafeRootBeforeCreatingExternalDirectories() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let external = fixture.directory.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.removeItem(at: fixture.paths.root)
        try FileManager.default.createSymbolicLink(at: fixture.paths.root, withDestinationURL: external)
        do {
            _ = try await DXVKInstallation.install(paths: fixture.paths)
            Issue.record("Installation unexpectedly adopted a symlinked data root")
        } catch is MagicWineError {
            #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        }
    }

    @Test func installationCannotAdoptCorruptCachedPackage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makePayload(at: fixture.component, metadata: true)
        let before = try Data(contentsOf: fixture.component.appendingPathComponent("x64/d3d11.dll"))
        do {
            _ = try await DXVKInstallation.install(paths: fixture.paths)
            Issue.record("Installation unexpectedly adopted an unpinned cached DLL")
        } catch is MagicWineError {
            #expect(try Data(contentsOf: fixture.component.appendingPathComponent("x64/d3d11.dll")) == before)
            #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.componentsDirectory.path) == [DXVKInstallation.componentID])
        }
    }

    @Test func publishCollisionLeavesExistingComponentAndStageUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.component, withIntermediateDirectories: false)
        let existing = fixture.component.appendingPathComponent("user-owned-content")
        let existingBytes = Data("do not replace me".utf8)
        try existingBytes.write(to: existing)
        let staged = fixture.paths.componentsDirectory.appendingPathComponent(".install-fixture")
        try makePayload(at: staged, metadata: true)
        #expect(throws: MagicWineError.self) { try DXVKInstallation.publish(staged, paths: fixture.paths) }
        #expect(try Data(contentsOf: existing) == existingBytes)
        #expect(FileManager.default.fileExists(atPath: staged.appendingPathComponent("x64/d3d11.dll").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.component.path) == ["user-owned-content"])
    }

    @Test func cancelledPublishNeverCreatesTheSelectedComponent() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let staged = fixture.paths.componentsDirectory.appendingPathComponent(".install-cancelled")
        try makePayload(at: staged, metadata: true)
        let publishing = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DXVKInstallation.publish(staged, paths: fixture.paths)
        }
        do {
            _ = try await publishing.value
            Issue.record("A cancelled publication unexpectedly succeeded")
        } catch is CancellationError {
            #expect(!FileManager.default.fileExists(atPath: fixture.component.path))
            #expect(FileManager.default.fileExists(atPath: staged.path))
        }
    }

    private func attribute(_ name: String, on url: URL) throws -> Data? {
        let size = url.path.withCString { getxattr($0, name, nil, 0, 0, XATTR_NOFOLLOW) }
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var data = Data(count: size)
        let received = data.withUnsafeMutableBytes { bytes in
            url.path.withCString { getxattr($0, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
        }
        guard received == size else { throw POSIXError(.EIO) }
        return data
    }

    private func setAttribute(_ name: String, value: Data, on url: URL) throws {
        let result = value.withUnsafeBytes { bytes in
            url.path.withCString { setxattr($0, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    @Test func downloadQuarantineIsPreservedRatherThanRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try makePayload(at: fixture.component)
        let archive = fixture.directory.appendingPathComponent("download.tar.gz")
        try Data([1]).write(to: archive)
        let quarantine = Data("0083;12345678;MagicWineTests;".utf8)
        let otherName = "com.magicwine.tests.preserved"
        let other = Data([0x42, 0xff])
        try setAttribute("com.apple.quarantine", value: quarantine, on: archive)
        try setAttribute(otherName, value: other, on: fixture.component)
        try DXVKInstallation.preserveQuarantine(from: archive, to: fixture.component)
        #expect(try attribute("com.apple.quarantine", on: archive) == quarantine)
        #expect(try attribute("com.apple.quarantine", on: fixture.component) == quarantine)
        #expect(try attribute(otherName, on: fixture.component) == other)
        #expect(try Data(contentsOf: fixture.component.appendingPathComponent("x64/d3d11.dll")) == pe(machine: 0x8664))
    }
}
