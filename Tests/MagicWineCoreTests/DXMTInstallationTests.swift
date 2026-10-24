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
        let root = DXMTInstallation.archiveRoot
        for malicious in ["../escape", "/etc/passwd", "\(root)/x86_64-windows/../outside", "\(root)/x86_64-windows/d3d12.dll",
                          "\(root)/x86_64-unix/winemetal.so/", "./\(root)/x86_64-unix/winemetal.so"] {
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
        for name in ["x86_64-windows/d3d11.dll", "i386-windows/d3d11.dll", "x86_64-unix/winemetal.so", "LICENSE-DXMT.txt",
                     DXMTInstallation.provenanceName] {
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

    @Test func installedComponentReferencesBundledArchivesAndKeepsItsNotices() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let component = try await DXMTInstallation.install(paths: fixture.paths)
        let receiptURL = component.appendingPathComponent("installation.json")
        let receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        let bundled = try #require(receipt["bundledArchives"] as? [String: String])
        #expect(bundled == DXMTInstallation.bundledArchives)
        #expect(bundled[DXMTInstallation.sourceArchiveName] == DXMTRemoteBuildPins.sourceSHA256)
        let provenance = try String(contentsOf: component.appendingPathComponent("PROVENANCE.txt"), encoding: .utf8)
        #expect(provenance.contains("\(DXMTInstallation.sourceArchiveName), SHA-256 \(DXMTRemoteBuildPins.sourceSHA256)"))
        for name in bundled.keys {
            #expect(!FileManager.default.fileExists(atPath: component.appendingPathComponent(name).path))
            let resource = try #require(DXMTInstallation.bundledResource(name))
            #expect(SHA256.hash(data: try Data(contentsOf: resource)).map { String(format: "%02x", $0) }.joined() == bundled[name])
        }

        // A copied archive is not part of this layout.
        let copy = component.appendingPathComponent(DXMTInstallation.stockArchiveName)
        try FileManager.default.copyItem(at: try #require(DXMTInstallation.bundledResource(DXMTInstallation.stockArchiveName)), to: copy)
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
        }
        try FileManager.default.removeItem(at: copy)
        _ = try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)

        // The receipt cannot drop or redirect the corresponding-source reference.
        let original = try Data(contentsOf: receiptURL)
        var redirected = bundled
        redirected[DXMTInstallation.sourceArchiveName] = String(repeating: "0", count: 64)
        for forged: Any? in [nil, redirected] {
            var changed = receipt
            changed["bundledArchives"] = forged
            try JSONSerialization.data(withJSONObject: changed).write(to: receiptURL, options: .atomic)
            #expect(throws: MagicWineError.self) {
                try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
            }
        }
        try original.write(to: receiptURL, options: .atomic)

        // Notices stay in the component: removing one, even with a matching forged receipt, is rejected.
        let license = component.appendingPathComponent("LICENSE-DXMT.txt")
        let saved = fixture.directory.appendingPathComponent("LICENSE-DXMT.txt")
        try FileManager.default.moveItem(at: license, to: saved)
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
        }
        var files = try #require(receipt["files"] as? [String: String])
        files["LICENSE-DXMT.txt"] = nil
        var forged = receipt
        forged["files"] = files
        try JSONSerialization.data(withJSONObject: forged).write(to: receiptURL, options: .atomic)
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
        }
        try original.write(to: receiptURL, options: .atomic)
        try FileManager.default.moveItem(at: saved, to: license)
        _ = try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: fixture.paths)
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

    private func nativeImage(symbolType: UInt8 = 0x0f, symbolName: String = "_macdrv_functions") -> Data {
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
        let name = Data((symbolName + "\0").utf8)
        data.replaceSubrange(97..<(97 + name.count), with: name)
        return data
    }

    // Structural fixtures only: parsed without loading or executing native code.
    private func linkedNativeImage(symbol: String, dependency: Bool) -> Data {
        var data = nativeImage(symbolName: symbol)
        let symbols = data.subdata(in: 80..<160)
        data.replaceSubrange(80..<160, with: Data(repeating: 0, count: 48))
        data.append(symbols)
        put32(3, at: 16, into: &data)
        put32(96, at: 20, into: &data)
        put32(128, at: 64, into: &data)
        put32(144, at: 72, into: &data)
        put32(dependency ? 0x0c : 0x8000001c, at: 80, into: &data)
        put32(48, at: 84, into: &data)
        let nameOffset = dependency ? 24 : 12
        put32(UInt32(nameOffset), at: 88, into: &data)
        let name = Data((dependency ? "@rpath/ntdll.so\0" : "@loader_path/\0").utf8)
        data.replaceSubrange((80 + nameOffset)..<(80 + nameOffset + name.count), with: name)
        return data
    }

    @Test func nativeRuntimeValidationDoesNotRequireDXMTHostEligibility() throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let bin = fixture.directory.appendingPathComponent("bin")
        let library = fixture.directory.appendingPathComponent("lib/wine")
        let native = library.appendingPathComponent("x86_64-unix")
        for directory in [bin, native] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let executable = bin.appendingPathComponent("wine")
        var loader = nativeImage()
        put32(2, at: 12, into: &loader)
        try loader.write(to: executable)
        try linkedNativeImage(symbol: "_macdrv_functions", dependency: true)
            .write(to: native.appendingPathComponent("winemac.so"))
        try linkedNativeImage(symbol: "_NtSetEvent", dependency: false)
            .write(to: native.appendingPathComponent("ntdll.so"))
        for (architecture, machine) in [("i386-windows", UInt16(0x014c)), ("x86_64-windows", UInt16(0x8664))] {
            let directory = library.appendingPathComponent(architecture)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var pe = Data(repeating: 0, count: 256)
            pe[0] = 0x4d; pe[1] = 0x5a; pe[60] = 128
            pe[128] = 0x50; pe[129] = 0x45
            pe[132] = UInt8(truncatingIfNeeded: machine)
            pe[133] = UInt8(truncatingIfNeeded: machine >> 8)
            pe[148] = 0x60; pe[151] = 0x20; pe[152] = 0x0b
            pe[153] = machine == 0x014c ? 0x01 : 0x02
            try pe.write(to: directory.appendingPathComponent("winemac.drv"))
        }

        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validateHost(macOSMajor: 14, supportsAppleGPU: false)
        }
        try DXMTInstallation.validateNativeRuntime(executable)
        try nativeImage().write(to: native.appendingPathComponent("ntdll.so"))
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validateNativeRuntime(executable)
        }
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
