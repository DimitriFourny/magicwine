import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct DXMTInstallationTests {
    private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var paths: ApplicationPaths { ApplicationPaths(root: directory.appendingPathComponent("Managed", isDirectory: true)) }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func archiveMembers() -> (entries: [String], types: [Character]) {
        let root = DXMTInstallation.archiveRoot
        let dirs = [root, root + "/i386-windows", root + "/x86_64-windows", root + "/x86_64-unix"]
        let files = DXMTInstallation.payloadDigests.keys.sorted().map { root + "/" + $0 }
        return (dirs.map { $0 + "/" } + files, dirs.map { _ in Character("d") } + files.map { _ in Character("-") })
    }

    @Test func acceptsExactArchiveAndRejectsDuplicatesMissingFilesAndTraversal() throws {
        let members = archiveMembers()
        try DXMTInstallation.validateArchiveMembers(members.entries, types: members.types)
        for malicious in ["../escape", "/etc/passwd", "v0.80/x86_64-windows/../outside", "v0.80/x86_64-windows/d3d12.dll",
                          "v0.80/x86_64-unix/winemetal.so/", "./v0.80/x86_64-unix/winemetal.so"] {
            var entries = members.entries
            entries[4] = malicious
            #expect(throws: MagicWineError.self) { try DXMTInstallation.validateArchiveMembers(entries, types: members.types) }
        }
        var duplicate = members.entries
        duplicate[4] = duplicate[5]
        #expect(throws: MagicWineError.self) { try DXMTInstallation.validateArchiveMembers(duplicate, types: members.types) }
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validateArchiveMembers(Array(members.entries.dropLast()), types: Array(members.types.dropLast()))
        }
    }

    @Test(arguments: [Character("l"), Character("h"), Character("b"), Character("p"), Character("d")])
    func rejectsArchiveLinksAndSpecialMembers(type: Character) throws {
        let members = archiveMembers()
        var types = members.types
        types[4] = type
        #expect(throws: MagicWineError.self) { try DXMTInstallation.validateArchiveMembers(members.entries, types: types) }
    }


    @Test func cachedAdoptionRejectsChangedFilesForgedReceiptsMissingFilesAndExtras() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let component = try await DXMTInstallation.install(paths: fixture.paths)
        // Same-size modifications invalidate inode/mtime/ctime cache evidence.
        for name in ["x86_64-windows/d3d11.dll", "i386-windows/d3d11.dll", "x86_64-unix/winemetal.so", "LICENSE-DXMT.txt"] {
            let target = component.appendingPathComponent(name)
            let original = try Data(contentsOf: target)
            var changed = original
            changed[changed.count - 1] ^= 1
            try changed.write(to: target, options: .atomic)
            // A new receipt copied from the compiled pin cannot bless changed payloads.
            try DXMTInstallation.writeReceipt(at: component)
            #expect(throws: MagicWineError.self) {
                try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
            }
            let receiptURL = component.appendingPathComponent("installation.json")
            var receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
            var files = try #require(receipt["files"] as? [String: String])
            files[name] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
            receipt["files"] = files
            try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL, options: .atomic)
            #expect(throws: MagicWineError.self) {
                try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
            }
            try DXMTInstallation.writeReceipt(at: component)
            try original.write(to: target, options: .atomic)
            _ = try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
        }
        let dll = component.appendingPathComponent("i386-windows/winemetal.dll")
        let original = try Data(contentsOf: dll)
        try FileManager.default.removeItem(at: dll)
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
        }
        try original.write(to: dll)
        try Data([1]).write(to: component.appendingPathComponent("x86_64-unix/foreign.so"))
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
        }
    }

    @Test func unsafeFilesAreRejectedAndExistingCorruptPublicationIsNeverReplaced() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let component = try await DXMTInstallation.install(paths: fixture.paths)
        let target = component.appendingPathComponent("x86_64-windows/dxgi.dll")
        let external = fixture.directory.appendingPathComponent("External.dll")
        try FileManager.default.linkItem(at: target, to: external)
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
        }
        try FileManager.default.removeItem(at: external)
        let original = try Data(contentsOf: target)
        try original.write(to: external)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: external)
        #expect(throws: MagicWineError.self) { try DXMTInstallation.environment(component: component, showHUD: false) }
        await #expect(throws: MagicWineError.self) { try await DXMTInstallation.install(paths: fixture.paths) }
        #expect(try Data(contentsOf: external) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == external.path)
    }

    @Test func rejectsLinkedManagedRootAndNonPinnedIDs() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let outside = fixture.directory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fixture.paths.root, withDestinationURL: outside)
        await #expect(throws: MagicWineError.self) { try await DXMTInstallation.install(paths: fixture.paths) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        for id in ["", "../escape", "/tmp/escape", "dxmt-v0.81"] {
            #expect(throws: MagicWineError.self) { try DXMTInstallation.validate(componentID: id, paths: fixture.paths) }
        }
    }

    @Test func hostAndDriverCapabilitiesFailClosed() throws {
        try DXMTInstallation.validateHost(macOSMajor: 15, supportsAppleGPU: true)
        #expect(throws: MagicWineError.self) { try DXMTInstallation.validateHost(macOSMajor: 14, supportsAppleGPU: true) }
        #expect(throws: MagicWineError.self) { try DXMTInstallation.validateHost(macOSMajor: 15, supportsAppleGPU: false) }
        try DXMTInstallation.validateDriverExports(["_macdrv_functions"])
        let individual: Set<String> = ["_get_win_data", "_release_win_data", "_macdrv_view_create_metal_view",
                                       "_macdrv_view_get_metal_layer", "_macdrv_view_release_metal_view"]
        try DXMTInstallation.validateDriverExports(individual)
        for missing in individual {
            #expect(throws: MagicWineError.self) { try DXMTInstallation.validateDriverExports(individual.subtracting([missing])) }
        }
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validateDriverExports(["___wine_unix_call_funcs", "___wine_unix_call_wow64_funcs"])
        }
    }

    private func put32(_ value: UInt32, at offset: Int, into data: inout Data) {
        for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * index)) }
    }

    private func nativeImage(symbolType: UInt8 = 0x0f) -> Data {
        var data = Data(repeating: 0, count: 160)
        put32(0xfeedfacf, at: 0, into: &data)
        put32(0x01000007, at: 4, into: &data)
        put32(6, at: 12, into: &data)
        put32(2, at: 16, into: &data)
        put32(48, at: 20, into: &data)
        put32(0x32, at: 32, into: &data)
        put32(24, at: 36, into: &data)
        put32(1, at: 40, into: &data)
        put32(0x000f0000, at: 44, into: &data)
        put32(2, at: 56, into: &data)
        put32(24, at: 60, into: &data)
        put32(80, at: 64, into: &data)
        put32(1, at: 68, into: &data)
        put32(96, at: 72, into: &data)
        put32(64, at: 76, into: &data)
        put32(1, at: 80, into: &data)
        data[84] = symbolType
        let name = Data("_macdrv_functions\0".utf8)
        data.replaceSubrange(97..<(97 + name.count), with: name)
        return data
    }

    @Test func nativeInspectionDistinguishesExportsFromImportsAndHiddenSymbols() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let binary = fixture.directory.appendingPathComponent("driver.so")
        try nativeImage().write(to: binary)
        let image = try DXMTInstallation.inspectMachO(binary)
        #expect(image.minimumOS == 0x000f0000)
        #expect(image.exports.contains("_macdrv_functions"))
        for type in [UInt8(0x01), 0x1f, 0xef] {
            try nativeImage(symbolType: type).write(to: binary)
            #expect(try DXMTInstallation.inspectMachO(binary).exports.isEmpty)
        }
    }

    @Test(arguments: ["arm64", "fat", "short", "commands", "commandSize", "symbolBounds", "stringBounds"])
    func rejectsMalformedOrWrongArchitectureMachO(fault: String) throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let binary = fixture.directory.appendingPathComponent("driver.so")
        var bytes = nativeImage()
        switch fault {
        case "arm64": put32(0x0100000c, at: 4, into: &bytes)
        case "fat": put32(0xcafebabe, at: 0, into: &bytes)
        case "short": bytes = Data(bytes.prefix(20))
        case "commands": put32(0xffffffff, at: 16, into: &bytes)
        case "commandSize": put32(0, at: 36, into: &bytes)
        case "symbolBounds": put32(0xffffffff, at: 64, into: &bytes)
        case "stringBounds": put32(65, at: 80, into: &bytes)
        default: Issue.record("Unexpected malformed fixture")
        }
        try bytes.write(to: binary)
        #expect(throws: MagicWineError.self) { try DXMTInstallation.inspectMachO(binary) }
    }
}
