import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct D3DMetalInstallationTests {
    private struct Fixture {
        let directory: URL
        let source: URL
        let paths: ApplicationPaths
        init() throws {
            directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            source = directory.appendingPathComponent("apple_gptk", isDirectory: true)
            paths = ApplicationPaths(root: directory.appendingPathComponent("Managed", isDirectory: true))
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        }
        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func put(_ bytes: Data, at root: URL, _ name: String) throws {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
    }

    private func uint32(_ value: UInt32, into data: inout Data, at offset: Int) {
        for i in 0..<4 { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }

    // Structural fixtures only, never executable Apple binaries or authenticity claims.
    private func pe(machine: UInt16 = 0x8664) -> Data {
        var bytes = Data(repeating: 0, count: 256)
        bytes.replaceSubrange(64..<81, with: Data("Wine builtin DLL\0".utf8))
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 128
        bytes[128] = 0x50; bytes[129] = 0x45
        bytes[132] = UInt8(truncatingIfNeeded: machine); bytes[133] = UInt8(truncatingIfNeeded: machine >> 8)
        bytes[148] = 96; bytes[151] = 0x20; bytes[152] = 0x0b; bytes[153] = 2
        return bytes
    }

    private func macho(cpu: UInt32 = 0x01000007, minimum: UInt32 = 14 << 16) -> Data {
        var bytes = Data(repeating: 0, count: 56)
        uint32(0xfeedfacf, into: &bytes, at: 0)
        uint32(cpu, into: &bytes, at: 4)
        uint32(6, into: &bytes, at: 12)
        uint32(1, into: &bytes, at: 16)
        uint32(24, into: &bytes, at: 20)
        uint32(0x32, into: &bytes, at: 32)
        uint32(24, into: &bytes, at: 36)
        uint32(1, into: &bytes, at: 40)
        uint32(minimum, into: &bytes, at: 44)
        return bytes
    }

    private func payload(_ root: URL, versioned: Bool = true) throws {
        for name in ["d3d11", "d3d12", "dxgi"] {
            try put(pe(), at: root, "wine/x86_64-windows/\(name).dll")
            try put(macho(), at: root, "wine/x86_64-unix/\(name).so")
        }
        try put(macho(), at: root, "external/libd3dshared.dylib")
        let framework = "external/D3DMetal.framework"
        let content = framework + (versioned ? "/Versions/A" : "")
        try put(macho(), at: root, content + "/D3DMetal")
        try put(macho(), at: root, content + "/Resources/libmetalirconverter.dylib")
        try put(Data("<plist/>".utf8), at: root, content + "/Resources/Info.plist")
        try put(Data("Preserved dependency attribution\n".utf8), at: root, content + "/Resources/LICENSE")
        if versioned {
            for (name, target) in [("D3DMetal", "Versions/Current/D3DMetal"), ("Resources", "Versions/Current/Resources"), ("Versions/Current", "A")] {
                try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(framework + "/" + name).path, withDestinationPath: target)
            }
        }
    }

    @Test(arguments: [true, false])
    func importIsContentAddressedAndReusableWithoutOriginalSource(versioned: Bool) async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try payload(fixture.source, versioned: versioned)
        let first = try await D3DMetalInstallation.install(paths: fixture.paths, source: fixture.source)
        let second = try await D3DMetalInstallation.install(paths: fixture.paths, source: fixture.source)
        #expect(first == second)
        #expect(D3DMetalInstallation.supports(componentID: first.lastPathComponent))
        try FileManager.default.removeItem(at: fixture.source)
        #expect(try D3DMetalInstallation.validate(componentID: first.lastPathComponent, paths: fixture.paths) == first)
    }

    @Test func missingBridgeAndWrongArchitecturesAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try payload(fixture.source)
        let dll = fixture.source.appendingPathComponent("wine/x86_64-windows/d3d11.dll")
        try pe(machine: 0x014c).write(to: dll)
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
        try pe().write(to: dll)
        let library = fixture.source.appendingPathComponent("wine/x86_64-unix/d3d12.so")
        try macho(cpu: 0x0100000c).write(to: library)
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
        try FileManager.default.removeItem(at: library)
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
    }

    @Test(arguments: ["../../../../outside", "/tmp", "../A", "A/../A"])
    func rejectsNoncanonicalFrameworkLinks(target: String) throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try payload(fixture.source)
        let link = fixture.source.appendingPathComponent("external/D3DMetal.framework/Versions/Current")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
    }

    @Test func rejectsLinkedRootLinkedPayloadAndHardlinkedInput() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try payload(fixture.source)
        let linkedRoot = fixture.directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.source)
        await #expect(throws: MagicWineError.self) {
            _ = try await D3DMetalInstallation.install(paths: fixture.paths, source: linkedRoot)
        }
        let bridge = fixture.source.appendingPathComponent("wine/x86_64-windows/d3d11.dll")
        let outside = fixture.directory.appendingPathComponent("outside.dll")
        try FileManager.default.copyItem(at: bridge, to: outside)
        try FileManager.default.removeItem(at: bridge)
        try FileManager.default.createSymbolicLink(at: bridge, withDestinationURL: outside)
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
        try FileManager.default.removeItem(at: bridge)
        try FileManager.default.linkItem(at: outside, to: bridge)
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
    }

    @Test func changedPayloadAndForgedReceiptCannotReusePinnedID() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try payload(fixture.source)
        let root = try await D3DMetalInstallation.install(paths: fixture.paths, source: fixture.source)
        let altered = root.appendingPathComponent("wine/x86_64-windows/d3d11.dll")
        var bytes = try Data(contentsOf: altered)
        bytes[200] = 7
        try bytes.write(to: altered)
        #expect(throws: MagicWineError.self) { _ = try D3DMetalInstallation.validate(componentID: root.lastPathComponent, paths: fixture.paths) }
        let receiptURL = root.appendingPathComponent("installation.json")
        var receipt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        var files = try #require(receipt["files"] as? [String: String])
        files["wine/x86_64-windows/d3d11.dll"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        receipt["files"] = files
        try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]).write(to: receiptURL)
        #expect(throws: MagicWineError.self) { _ = try D3DMetalInstallation.validate(componentID: root.lastPathComponent, paths: fixture.paths) }
        await #expect(throws: MagicWineError.self) {
            _ = try await D3DMetalInstallation.install(paths: fixture.paths, source: fixture.source)
        }
    }

    @Test func officialWrapperPreservesAccompanyingTermsAndQuarantine() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        let redist = fixture.source.appendingPathComponent("redist/lib")
        try payload(redist)
        let terms = Data("User-supplied terms, not accepted by MagicWine\n".utf8)
        try put(terms, at: fixture.source, "Software License Agreement.rtf")
        let quarantine = Data("0081;00000000;Test;".utf8)
        let result = quarantine.withUnsafeBytes { bytes in
            fixture.source.path.withCString { setxattr($0, "com.apple.quarantine", bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
        }
        #expect(result == 0)
        let root = try await D3DMetalInstallation.install(paths: fixture.paths, source: fixture.source)
        #expect(try Data(contentsOf: root.appendingPathComponent("Notices/Software License Agreement.rtf")) == terms)
        let dll = root.appendingPathComponent("wine/x86_64-windows/d3d11.dll")
        var bytes = Data(count: quarantine.count)
        let count = bytes.withUnsafeMutableBytes { buffer in
            dll.path.withCString { getxattr($0, "com.apple.quarantine", buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW) }
        }
        #expect(count == quarantine.count)
        #expect(bytes == quarantine)
    }

    @Test func rejectsUnknownFilesOptionalHalfPairsAndMalformedMachO() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try payload(fixture.source)
        let unknown = fixture.source.appendingPathComponent("run.sh")
        try Data("do not execute".utf8).write(to: unknown)
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
        try FileManager.default.removeItem(at: unknown)
        try put(pe(), at: fixture.source, "wine/x86_64-windows/nvngx.dll")
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
        try put(macho(), at: fixture.source, "wine/x86_64-unix/nvngx.so")
        var truncated = macho()
        uint32(UInt32.max, into: &truncated, at: 36)
        try put(truncated, at: fixture.source, "external/libd3dshared.dylib")
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
    }

    @Test(arguments: ["../d3dmetal-", "d3dmetal-" + String(repeating: "A", count: 64), "d3dmetal-" + String(repeating: "0", count: 63), "d3dmetal-" + String(repeating: "0", count: 64) + "/child"])
    func rejectsInvalidComponentIdentifiers(id: String) throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        #expect(!D3DMetalInstallation.supports(componentID: id))
        #expect(throws: MagicWineError.self) { _ = try D3DMetalInstallation.validate(componentID: id, paths: fixture.paths) }
    }

    @Test(arguments: [GraphicsBackend.d3dmetal, GraphicsBackend.dxmt])
    func privateViewSelectsProviderWithoutChangingRuntimeOrChildLoader(backend: GraphicsBackend) throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let runtime = fixture.directory.appendingPathComponent("Runtime")
        let loader = runtime.appendingPathComponent("bin/wineloader")
        try put(macho(), at: runtime, "bin/wineloader")
        try put(Data("#!/bin/sh\nexit 1\n".utf8), at: runtime, "bin/wine")
        try put(macho(), at: runtime, "bin/wineserver")
        try put(macho(), at: runtime, "lib/wine/x86_64-unix/ntdll.so")
        // Real Wine packages can hard-link their child loader. Read-only inputs are
        // safe to copy; the managed view must still contain independent regular files.
        try FileManager.default.linkItem(at: loader, to: runtime.appendingPathComponent("lib/wine/x86_64-unix/wine"))
        let original = Data("Original Wine graphics provider".utf8)
        try put(original, at: runtime, "lib/wine/x86_64-windows/d3d11.dll")
        try put(pe(), at: runtime, "lib/wine/x86_64-windows/kernel32.dll")
        try payload(fixture.source)
        if backend == .dxmt {
            for architecture in ["x86_64-windows", "i386-windows"] {
                for name in ["d3d10core", "d3d11", "dxgi", "winemetal"] {
                    try put(pe(), at: fixture.source, architecture + "/" + name + ".dll")
                }
            }
            try put(macho(), at: fixture.source, "x86_64-unix/winemetal.so")
            try put(pe(), at: fixture.source, "x86_64-windows/nvapi64.dll")
        }
        let selected = try GraphicsRuntimeView.prepare(executable: loader, component: fixture.source,
                                                       backend: backend, paths: fixture.paths)
        let view = selected.deletingLastPathComponent().deletingLastPathComponent()
        let provider = backend == .d3dmetal ? fixture.source.appendingPathComponent("wine") : fixture.source
        #expect(selected != loader)
        #expect(try Data(contentsOf: selected) == Data(contentsOf: loader))
        #expect(try Data(contentsOf: runtime.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll")) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: view.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll").path) ==
                provider.appendingPathComponent("x86_64-windows/d3d11.dll").path)
        for relative in ["bin/wine", "bin/wine64", "lib/wine/x86_64-unix/wine", "lib/wine/x86_64-unix/ntdll.so"] {
            var status = stat()
            #expect(view.appendingPathComponent(relative).path.withCString { lstat($0, &status) } == 0)
            #expect(status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG))
        }
        #expect(!FileManager.default.fileExists(atPath: view.appendingPathComponent("lib/wine/x86_64-windows/nvapi64.dll").path))
        #expect(try GraphicsRuntimeView.prepare(executable: loader, component: fixture.source,
                                               backend: backend, paths: fixture.paths) == selected)
        try Data("changed copy".utf8).write(to: selected)
        #expect(throws: MagicWineError.self) {
            _ = try GraphicsRuntimeView.prepare(executable: loader, component: fixture.source,
                                                backend: backend, paths: fixture.paths)
        }
    }

    @Test func privateViewRejectsEscapingRuntimeLink() throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let runtime = fixture.directory.appendingPathComponent("Runtime")
        try put(macho(), at: runtime, "bin/wineloader")
        try put(macho(), at: runtime, "lib/wine/x86_64-unix/ntdll.so")
        try FileManager.default.createSymbolicLink(atPath: runtime.appendingPathComponent("bin/escape").path,
                                                  withDestinationPath: "/bin/sh")
        try payload(fixture.source)
        #expect(throws: MagicWineError.self) {
            _ = try GraphicsRuntimeView.prepare(executable: runtime.appendingPathComponent("bin/wineloader"),
                                                component: fixture.source, backend: .d3dmetal, paths: fixture.paths)
        }
    }

    @Test func rejectsNativeReplacementAndUnsupportedDeploymentTarget() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try payload(fixture.source)
        var native = pe()
        native[64] = 0
        try put(native, at: fixture.source, "wine/x86_64-windows/d3d11.dll")
        #expect(throws: MagicWineError.self) { try D3DMetalInstallation.inspectPayload(fixture.source) }
        try put(pe(), at: fixture.source, "wine/x86_64-windows/d3d11.dll")
        try put(macho(minimum: 0xffff0000), at: fixture.source, "external/libd3dshared.dylib")
        await #expect(throws: MagicWineError.self) {
            _ = try await D3DMetalInstallation.install(paths: fixture.paths, source: fixture.source)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.componentsDirectory.path).isEmpty)
    }

    @Test func simultaneousPrivateViewPublicationReusesWinnerAndRejectsLinkedParent() async throws {
        let fixture = try Fixture(); defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let runtime = fixture.directory.appendingPathComponent("Runtime")
        let loader = runtime.appendingPathComponent("bin/wineloader")
        try put(macho(), at: runtime, "bin/wineloader")
        try put(macho(), at: runtime, "lib/wine/x86_64-unix/ntdll.so")
        try payload(fixture.source)
        let source = fixture.source, paths = fixture.paths
        let first = Task.detached {
            try GraphicsRuntimeView.prepare(executable: loader, component: source, backend: .d3dmetal, paths: paths)
        }
        let second = Task.detached {
            try GraphicsRuntimeView.prepare(executable: loader, component: source, backend: .d3dmetal, paths: paths)
        }
        let results = await (first.result, second.result)
        #expect(try results.0.get() == results.1.get())
        let parent = paths.runtimesDirectory.appendingPathComponent(".graphics-views")
        try FileManager.default.removeItem(at: parent)
        let outside = fixture.directory.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
        #expect(throws: MagicWineError.self) {
            _ = try GraphicsRuntimeView.prepare(executable: loader, component: source, backend: .d3dmetal, paths: paths)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
