import CryptoKit
import Foundation
import Testing
@testable import MagicWineCore

struct DXMTHistoricalInstallationTests {
    // Exact schema-1 publication metadata, independent of the current installer.
    private static let receipt = #"""
    {
      "schema": 1,
      "componentID": "dxmt-v0.80",
      "source": "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz",
      "archiveSHA256": "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
      "files": {
        "i386-windows/d3d10core.dll": "c5a26310d14a30c3e1700a4d0c9865be28a11351a5c4dc5b83ab1bd8fcf7662f",
        "i386-windows/d3d11.dll": "9afc2b3419818618c4c87274435a28935b0df002caa4b9a8d3a88d3dc846b17d",
        "i386-windows/dxgi.dll": "7df8cdf66e12a108410002abc77b01f70aa59b8a36a70fa0bc6ae3b056841319",
        "i386-windows/winemetal.dll": "20a6865facebdaac92b6c06fadf37d2efb5a242b22ca1c349bb57d7ad43df8e3",
        "x86_64-unix/winemetal.so": "3d50d7f39c64778c71d0af2fce1cde818d09ffbce7c4f7b8ae24ae1df567c0ca",
        "x86_64-windows/d3d10core.dll": "833d26971abc8661efc8b5cc18548c70ce8e482e4ea4b1d3f69a367612264d26",
        "x86_64-windows/d3d11.dll": "7ca382af0eb32d8a432f6efb14d594fefb45673663be1f7e6682254bff885c47",
        "x86_64-windows/dxgi.dll": "fc58aae0aba511a1ec4d2417e5bba6adb888bb14315d0f59cccdfd27f670d544",
        "x86_64-windows/nvapi64.dll": "7c37b66a88aa1fdb08c6035a7fe738af1c1b5eea53af78c4812498d22bef8bc3",
        "x86_64-windows/nvngx.dll": "18d5847ee524ba6eeb2eee656817ddc00a45c46759a753854335a765e997e5fe",
        "x86_64-windows/winemetal.dll": "514245d533c750599614311a792c45ed600aef52948571d98c0fc70fd3df16e0",
        "dxmt-v0.80-builtin.tar.gz": "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
        "LICENSE-DXMT.txt": "0acf1ce81dc7bbc0165f2f95ea359f37dc6bbe6546ef9f5feefa33496a942624",
        "PROVENANCE.txt": "a46d4a8d8ada378fb5c7242d5dcacc96648f17800fb8187812630328a7c0e4e5"
      }
    }
    """#
    private static let provenance = #"""
    MagicWine DXMT component: dxmt-v0.80
    Upstream: https://github.com/3Shain/dxmt/tree/589adb780354b461645b29999cefaf533594ee99
    Release archive: https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz
    Archive SHA-256: 8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d
    Checksum authority: upstream GitHub release asset digest; independently recorded file pins.
    License: MIT at v0.80 (last MIT release); dependency notices in LICENSE-DXMT.txt.
    Upstream build: .github/workflows/ci.yml at the pinned source commit;
    LLVM 15.0.7, public 3Shain/wine v8.16-3shain, LLVM-MinGW 20251216.
    
    The release archive and all payload bytes are unmodified. Original release
    archive is retained as dxmt-v0.80-builtin.tar.gz. No binaries from CrossOver
    or proprietary Apple components are redistributed.
    Wine 11 set_dll_path searches its runtime before WINEDLLPATH. Therefore
    setting WINEDLLPATH alone cannot replace builtin WineD3D. Launch MUST use
    MagicWine's isolated GraphicsRuntimeView overlaid with these DXMT PEs and
    winemetal.so, not the original Wine loader. Overrides are builtin-only.
    Loader reference: https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/ntdll/unix/loader.c
    WINEDLLPATH is this component root, NOT the x86_64-unix subdirectory.
    Wine appends the architecture suffix and associates winemetal.dll with
    x86_64-unix/winemetal.so for both PE architectures. Wine ntdll's LC_RPATH
    resolves @rpath/ntdll.so and @rpath/winemac.so in the selected runtime view.
    No shared Wine files, DLL registry overrides, or dyld globals are changed.
    Optional nvapi64/nvngx remain archived and verified, but are not enabled.
    DXMT — Experimental translates Direct3D 10/11 to Metal, not Direct3D 9/12. This pinned, unmodified MIT-licensed v0.80 package requires macOS 15 or later, an Apple Silicon Metal GPU, Rosetta and a compatible custom Wine runtime exposing the Metal-view interface. Stock managed Wine 11 lacks that interface: select a compatible custom Wine runtime in Settings before creating a new bottle. An isolated process-local loader view prevents runtime WineD3D or winemetal from shadowing DXMT; the shared runtime is never modified. No CrossOver or Apple proprietary binaries are bundled. Quarantine and the original release archive are preserved. Restore Standard before updating a component.
    
    """#

    @Test func preservesAuthenticStockPinAndRejectsCorruptionAndRelabelling() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let paths = ApplicationPaths(root: temporary.appendingPathComponent("Managed"))
        let current = try await DXMTInstallation.install(paths: paths)
        let savedCurrent = temporary.appendingPathComponent("current-publication")
        let extraction = temporary.appendingPathComponent("stock-extraction")
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
        _ = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: [
            "-xf", current.appendingPathComponent(DXMTInstallation.stockArchiveName).path,
            "-C", extraction.path, "--no-same-owner", "--no-same-permissions"
        ], paths: paths, name: "historical-dxmt-fixture", timeout: 180)
        let historical = paths.componentsDirectory.appendingPathComponent("dxmt-v0.80")
        try FileManager.default.moveItem(at: extraction.appendingPathComponent("v0.80"), to: historical)
        for name in [DXMTInstallation.stockArchiveName, "LICENSE-DXMT.txt"] {
            try FileManager.default.copyItem(at: current.appendingPathComponent(name), to: historical.appendingPathComponent(name))
        }
        let receiptURL = historical.appendingPathComponent("installation.json")
        try Data(Self.receipt.utf8).write(to: receiptURL)
        try Data(Self.provenance.utf8).write(to: historical.appendingPathComponent("PROVENANCE.txt"))
        let configuration = GraphicsConfiguration(backend: .dxmt, componentID: "dxmt-v0.80", showHUD: true)
        #expect(configuration.usesCurrentComponent)
        let validated = try DXMTInstallation.validate(componentID: "dxmt-v0.80", paths: paths)
        _ = try DXMTInstallation.environment(component: validated, showHUD: configuration.showHUD)
        _ = try await DXMTInstallation.install(paths: paths)
        #expect(try Data(contentsOf: receiptURL) == Data(Self.receipt.utf8))

        // Stock and source-built components cannot be substituted by relabelling.
        try FileManager.default.moveItem(at: current, to: savedCurrent)
        try FileManager.default.moveItem(at: historical, to: current)
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validate(componentID: DXMTInstallation.componentID, paths: paths)
        }
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.environment(component: current, showHUD: false)
        }
        try FileManager.default.moveItem(at: current, to: historical)
        try FileManager.default.moveItem(at: savedCurrent, to: current)

        let dll = historical.appendingPathComponent("x86_64-windows/d3d11.dll")
        let original = try Data(contentsOf: dll)
        var changed = original
        changed[changed.count - 1] ^= 1
        try changed.write(to: dll, options: .atomic)
        var receipt = try #require(JSONSerialization.jsonObject(with: Data(Self.receipt.utf8)) as? [String: Any])
        var files = try #require(receipt["files"] as? [String: String])
        files["x86_64-windows/d3d11.dll"] = SHA256.hash(data: changed).map { String(format: "%02x", $0) }.joined()
        receipt["files"] = files
        try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL, options: .atomic)
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.validate(componentID: "dxmt-v0.80", paths: paths)
        }
        try Data(Self.receipt.utf8).write(to: receiptURL, options: .atomic)
        #expect(throws: MagicWineError.self) {
            try DXMTInstallation.environment(component: historical, showHUD: false)
        }
        try original.write(to: dll, options: .atomic)
        _ = try DXMTInstallation.validate(componentID: "dxmt-v0.80", paths: paths)
    }
}
