import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct DXMTWineDriverTests {
    @Test func bundledNativeDriverHasRealExportsAndStockLinkage() throws {
        let artifacts = try DXMTWineDriver.bundledArtifacts()
        let driver = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".so")
        defer { try? FileManager.default.removeItem(at: driver) }
        try DXMTWineDriver.unpackDriver(try #require(artifacts.first), to: driver)
        let info = try DXMTInstallation.inspectMachO(driver)
        let required: Set<String> = [
            "_get_win_data", "_release_win_data", "_macdrv_view_create_metal_view",
            "_macdrv_view_get_metal_layer", "_macdrv_view_release_metal_view",
            "_macdrv_functions", "_magicwine_dxmt_bridge_v1",
            "___wine_unix_call_funcs", "___wine_unix_call_wow64_funcs"
        ]
        #expect(required.isSubset(of: info.exports))
        #expect(info.fileType == 6)
        #expect(info.dependencies.contains("@rpath/ntdll.so"))
        #expect(info.dependencies.contains("@rpath/win32u.so"))
        try DXMTInstallation.validateDriverExports(info.exports)
    }

    @Test func dxmtBridgeIsNotAdvertisedAsAppleD3DMetal() throws {
        #if arch(arm64)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let native = root.appendingPathComponent("lib/wine/x86_64-unix")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let artifact = try #require(DXMTWineDriver.bundledArtifacts().first)
        // No image is executed. The native validator accepts a Mach-O loader header;
        // copying the real bundled image keeps the marker/table regression binary-based.
        let executable = bin.appendingPathComponent("wine")
        try DXMTWineDriver.unpackDriver(artifact, to: executable)
        try FileManager.default.copyItem(at: executable, to: native.appendingPathComponent("winemac.so"))
        #expect(throws: MagicWineError.self) {
            try D3DMetalInstallation.validateRuntime(executable)
        }
        #endif
    }

    @Test func rejectsLinkedLayoutWithoutMutatingItsTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("owned")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: owned.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let sentinel = external.appendingPathComponent("unchanged")
        try Data("do not modify".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: owned.appendingPathComponent("lib"), withDestinationURL: external)
        let executable = owned.appendingPathComponent("bin/wine")
        try Data("untrusted runtime".utf8).write(to: executable)
        #expect(throws: MagicWineError.self) { try DXMTWineDriver.install(at: executable) }
        #expect(throws: MagicWineError.self) { try DXMTWineDriver.validate(at: executable) }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "do not modify")
        #expect(!FileManager.default.fileExists(atPath: owned.appendingPathComponent("runtime-compatibility").path))
    }

    @Test func rejectsUnknownNativeABIWithoutWritingBackupOrDriver() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let native = root.appendingPathComponent("lib/wine/x86_64-unix")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("wine")
        let driver = native.appendingPathComponent("winemac.so")
        try Data("untrusted executable".utf8).write(to: executable)
        try Data("custom driver".utf8).write(to: driver)
        for name in ["ntdll.so", "win32u.so"] {
            try Data("unknown ABI".utf8).write(to: native.appendingPathComponent(name))
        }
        #expect(throws: MagicWineError.self) { try DXMTWineDriver.install(at: executable) }
        #expect(throws: MagicWineError.self) { try DXMTWineDriver.validate(at: executable) }
        #expect(try String(contentsOf: driver, encoding: .utf8) == "custom driver")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime-compatibility").path))
    }
}
