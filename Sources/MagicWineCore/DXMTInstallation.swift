import Darwin
import Foundation
import Metal

/// MIT DXMT v0.80 with source-built, capability-gated remote Metal presentation.
/// Both winemetal PEs and the Unix bridge are an inseparable ABI-matched set.
enum DXMTInstallation {
    static let componentID = "dxmt-v0.80-remote.1"
    static let archiveRoot = componentID
    static let archiveName = componentID
    static let archiveSHA256 = DXMTRemoteBuildPins.archiveSHA256
    static let source = "bundled:Sources/MagicWineCore/Resources/\(componentID).tar.gz"
    static let sourceArchiveName = componentID + "-source.tar.gz"
    static let provenanceName = componentID + "-provenance.json"
    static let stockArchiveName = "dxmt-v0.80-builtin.tar.gz"
    private static let stockArchiveSHA256 = "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
    static let notice = "DXMT — Experimental translates Direct3D 10/11 to Metal, not Direct3D 9/12. This altered MIT-licensed v0.80 package requires macOS 15 or later, an Apple Silicon Metal GPU, Rosetta and compatible Wine. MagicWine rebuilds the matched D3D11 and Metal-view modules for real cross-process presentation on its managed Wine driver; unsupported custom drivers fail gracefully. All other public upstream payloads are unchanged. Complete corresponding source, build inputs, patches, licenses and provenance are bundled. No CrossOver or Apple proprietary runtime binaries are included. Standard graphics remains the default. An isolated process-local loader view prevents WineD3D from shadowing DXMT without modifying shared Wine files."
    private static let directories: Set<String> = ["i386-windows", "x86_64-windows", "x86_64-unix"]
    private static let licenseSHA256 = "0acf1ce81dc7bbc0165f2f95ea359f37dc6bbe6546ef9f5feefa33496a942624"
    // Generated only from the completed source build, independently of receipts.
    static let payloadDigests = DXMTRemoteBuildPins.payloadDigests
    private static let provenance = """
    MagicWine DXMT component: \(componentID)
    Upstream MIT release: https://github.com/3Shain/dxmt/tree/589adb780354b461645b29999cefaf533594ee99
    Original release: https://github.com/3Shain/dxmt/releases/download/v0.80/\(stockArchiveName)
    Original release SHA-256: \(stockArchiveSHA256)
    Altered archive SHA-256: \(archiveSHA256)
    Corresponding source: \(sourceArchiveName), SHA-256 \(DXMTRemoteBuildPins.sourceSHA256)
    Build provenance: \(provenanceName), SHA-256 \(DXMTRemoteBuildPins.provenanceSHA256)
    Recipe: scripts/build-dxmt.sh; source changes: patches/dxmt-remote-metal.patch.
    The matched i386/x86_64 d3d11.dll, winemetal.dll and x86_64 winemetal.so are
    source-built. All other payloads and retained upstream archive are unchanged.
    Native magicwine_metal_remote_v1 capability gates foreign HWND/root support;
    real window ownership is preserved. Native acquisition failures return E_FAIL.
    Immutable generated shader arrays are retained from the verified public
    archive, with named-symbol extraction, independent pins and full shader source.
    Build-input licenses remain in the corresponding-source bundle.
    Launch MUST use MagicWine's isolated GraphicsRuntimeView. Builtin overrides
    and the component-root WINEDLLPATH prevent WineD3D from shadowing DXMT.
    Optional upstream NVAPI/NVNGX remain verified but are not enabled.

    """
    private struct Receipt: Codable, Equatable {
        let schema: Int
        let componentID: String
        let source: String
        let archiveSHA256: String
        let files: [String: String]
    }
    private static var expectedFiles: [String: String] {
        var files = payloadDigests
        files[archiveName + ".tar.gz"] = archiveSHA256
        files["LICENSE-DXMT.txt"] = licenseSHA256
        files[stockArchiveName] = stockArchiveSHA256
        files[sourceArchiveName] = DXMTRemoteBuildPins.sourceSHA256
        files[provenanceName] = DXMTRemoteBuildPins.provenanceSHA256
        files["PROVENANCE.txt"] = SecureFS.digest(Data(provenance.utf8))
        return files
    }
    private static var expectedReceipt: Receipt {
        Receipt(schema: 2, componentID: componentID, source: source,
                archiveSHA256: archiveSHA256, files: expectedFiles)
    }

    // Retained older components: each is immutable and validated against its own
    // receipt, never an alias for the current build. Bottles pinned to them keep
    // launching and can be updated in place. Move `expectedReceipt` here (as a literal)
    // when the current pin changes.
    private static let retainedReceipts = [Receipt(
        schema: 1, componentID: "dxmt-v0.80",
        source: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz",
        archiveSHA256: "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
        files: [
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
            "PROVENANCE.txt": "a46d4a8d8ada378fb5c7242d5dcacc96648f17800fb8187812630328a7c0e4e5",
        ])]

    static var retainedComponentIDs: [String] { retainedReceipts.map(\.componentID) }

    private static func pinnedReceipt(for requested: String) throws -> Receipt {
        if requested == componentID { return expectedReceipt }
        guard let receipt = retainedReceipts.first(where: { $0.componentID == requested }) else {
            throw MagicWineError.setup("Unsupported DXMT component \(requested). Restore Standard before selecting the current DXMT component.")
        }
        return receipt
    }
    private static let fs = SecureFS(prefix: "DXMT: ")
    private static let cache = SecureFS.ValidationCache()
    /// Historical limit of the DXVK PE validator these DLL checks originally shared.
    private static let peMaximum = 32 * 1_048_576

    private static func maximum(for name: String) -> Int {
        name == sourceArchiveName ? 1_024 * 1_048_576 : 64 * 1_048_576
    }

    private static func requireFile(_ url: URL) throws {
        try fs.requireFile(url, maximum: maximum(for: url.lastPathComponent))
    }

    static func install(paths: ApplicationPaths,
                        progress: (@Sendable (GraphicsSetupProgress) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard paths.root.isFileURL else { throw MagicWineError.setup("DXMT requires a local data directory.") }
        if try fs.exists(paths.root) {
            try fs.requireDirectory(paths.root)
            if try fs.exists(paths.componentsDirectory) { try fs.requireDirectory(paths.componentsDirectory) }
        }
        try paths.prepare()
        try validateManagedParents(paths)
        let destination = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
        if try fs.exists(destination) {
            progress?(.verifying)
            try validateRoot(destination)
            try Task.checkCancellation()
            return destination
        }
        let stage = paths.componentsDirectory.appendingPathComponent(".install-dxmt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        guard let bundled = Bundle.module.url(forResource: archiveName, withExtension: "tar.gz"),
              let license = Bundle.module.url(forResource: "LICENSE-DXMT", withExtension: "txt") else {
            throw MagicWineError.setup("Bundled DXMT archive or notices are missing. Reinstall MagicWine; no network fallback is used.")
        }
        progress?(.verifying)
        try requireFile(bundled)
        try requireFile(license)
        let archive = stage.appendingPathComponent(archiveName + ".tar.gz")
        let extraction = try await BundledArchive.extract(bundled, to: archive, sha256: archiveSHA256,
            maximum: 32 * 1_048_576, toolPrefix: "dxmt", paths: paths, fs: fs,
            progress: progress, validateMembers: validateArchiveMembers)
        let component = extraction.appendingPathComponent(archiveRoot, isDirectory: true)
        try validatePayloadLayout(at: component)
        for (name, expected) in payloadDigests {
            guard try fs.sha256(component.appendingPathComponent(name), maximum: 64 * 1_048_576) == expected else {
                throw MagicWineError.setup("DXMT pinned payload checksum mismatch: \(name).")
            }
        }
        try FileManager.default.moveItem(at: archive, to: component.appendingPathComponent(archiveName + ".tar.gz"))
        try FileManager.default.copyItem(at: license, to: component.appendingPathComponent("LICENSE-DXMT.txt"))
        try Data(provenance.utf8).write(to: component.appendingPathComponent("PROVENANCE.txt"), options: .atomic)
        for name in [stockArchiveName, sourceArchiveName, provenanceName] {
            guard let resource = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw MagicWineError.setup("Bundled DXMT corresponding source or provenance is missing: \(name). Reinstall MagicWine.")
            }
            try requireFile(resource)
            let target = component.appendingPathComponent(name)
            try FileManager.default.copyItem(at: resource, to: target)
            try fs.preserveQuarantine(from: resource, to: target)
        }
        try writeReceipt(at: component)
        // Propagate quarantine to every loadable copy, not only its enclosing directory.
        try fs.preserveQuarantine(from: bundled, to: component)
        for name in payloadDigests.keys {
            try fs.preserveQuarantine(from: bundled, to: component.appendingPathComponent(name))
        }
        try validateRoot(component)
        return try publish(component, paths: paths)
    }

    static func validate(componentID requested: String, paths: ApplicationPaths) throws -> URL {
        _ = try pinnedReceipt(for: requested)
        try validateManagedParents(paths)
        let root = paths.componentsDirectory.appendingPathComponent(requested, isDirectory: true)
        try validateRoot(root)
        return root
    }

    static func environment(component: URL, showHUD: Bool) throws -> [String: String] {
        guard component.isFileURL, !component.path.contains(":"), !component.path.contains("\n") else {
            throw MagicWineError.setup("DXMT component paths cannot contain colon or newline characters (Wine DLL search-path delimiters).")
        }
        try validateRoot(component)
        return ["WINEDLLPATH": component.path,
                "WINEDLLOVERRIDES": "d3d10core,d3d11,dxgi,winemetal=b",
                "MTL_HUD_ENABLED": showHUD ? "1" : "0"]
    }

    static func validateHost(macOSMajor: Int, supportsAppleGPU: Bool) throws {
        guard macOSMajor >= 15 else {
            throw MagicWineError.setup("This DXMT v0.80 native library requires macOS 15 or later; its Mach-O deployment target is 15.0.")
        }
        guard supportsAppleGPU else {
            throw MagicWineError.setup("This DXMT configuration requires an Apple Silicon GPU (Metal Apple7 or newer). Non-Apple GPU support is not enabled.")
        }
    }

    static func validateRuntime(_ executable: URL) throws {
        try validateHost(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
                         supportsAppleGPU: MTLCopyAllDevices().contains { $0.supportsFamily(.apple7) })
        try validateNativeRuntime(executable)
    }

    static func validateNativeRuntime(_ executable: URL) throws {
        guard executable.isFileURL, ["wine", "wine64", "wineloader"].contains(executable.lastPathComponent) else {
            throw MagicWineError.setup("DXMT requires a compatible Wine executable, not a wrapper script.")
        }
        let resolved = executable.resolvingSymlinksInPath()
        let bin = resolved.deletingLastPathComponent()
        let unix: URL
        if bin.lastPathComponent == "bin" {
            unix = bin.deletingLastPathComponent().appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        } else if bin.lastPathComponent == "x86_64-unix" { unix = bin }
        else { throw MagicWineError.setup("DXMT requires Wine's bin/wine or lib/wine/x86_64-unix/wine layout.") }
        try fs.requireDirectory(unix)
        let loader = try inspectMachO(resolved)
        guard loader.fileType == 2 else { throw MagicWineError.setup("DXMT requires a native x86_64 Wine loader.") }
        let driver = try inspectMachO(unix.appendingPathComponent("winemac.so"))
        try validateDriverExports(driver.exports)
        let ntdll = try inspectMachO(unix.appendingPathComponent("ntdll.so"))
        guard ntdll.fileType == 6, ntdll.exports.contains("_NtSetEvent"),
              ntdll.rpaths.contains("@loader_path/") || ntdll.rpaths.contains("@loader_path") else {
            throw MagicWineError.setup("DXMT requires Wine ntdll.so with NtSetEvent and a runtime-local @loader_path rpath for native linkage.")
        }
        guard driver.fileType == 6, driver.dependencies.contains("@rpath/ntdll.so") else {
            throw MagicWineError.setup("DXMT requires a compatible dynamically linked macOS Wine driver.")
        }
        let wineLib = unix.deletingLastPathComponent()
        for architecture in ["i386-windows", "x86_64-windows"] {
            let directory = wineLib.appendingPathComponent(architecture, isDirectory: true)
            try fs.requireDirectory(directory)
            try PEInspector.validateDLL(directory.appendingPathComponent("winemac.drv"),
                                        machine: architecture == "i386-windows" ? PEInspector.i386 : PEInspector.amd64,
                                        fs: fs, maximum: peMaximum)
        }
    }

    static func validateDriverExports(_ exports: Set<String>) throws {
        let individual: Set<String> = ["_get_win_data", "_release_win_data", "_macdrv_view_create_metal_view",
                                       "_macdrv_view_get_metal_layer", "_macdrv_view_release_metal_view"]
        guard exports.contains("_macdrv_functions") || individual.isSubset(of: exports) else {
            throw MagicWineError.setup("This bottle's Wine does not provide DXMT's Metal-view interface. Use Install Wine in Downloads or Settings, then create a new bottle with the installed Wine. Installing Wine does not change this bottle's pinned runtime. A compatible custom Wine runtime can also be selected for a new bottle. DXMT was not enabled; this bottle's graphics selection is unchanged.")
        }
    }

    static func validateArchiveMembers(_ entries: [String], types: [Character]) throws {
        let dirs = Set([archiveRoot] + directories.map { archiveRoot + "/" + $0 })
        let files = Set(payloadDigests.keys.map { archiveRoot + "/" + $0 })
        let normalized = entries.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        guard entries.count == dirs.count + files.count, types.count == entries.count,
              Set(normalized) == dirs.union(files), Set(normalized).count == normalized.count,
              entries.allSatisfy({ !$0.hasSuffix("/") || dirs.contains(String($0.dropLast())) }) else {
            throw MagicWineError.setup("DXMT archive contains missing, duplicate, unsafe, or unexpected paths.")
        }
        for (entry, type) in zip(normalized, types) {
            guard dirs.contains(entry) ? type == "d" : type == "-" else {
                throw MagicWineError.setup("DXMT archive contains a link or special member: \(entry).")
            }
        }
    }

    static func validatePayloadLayout(at root: URL, includesMetadata: Bool = false) throws {
        try fs.requireDirectory(root)
        let payloadNames = Array(payloadDigests.keys)
        var expected = Set(payloadNames).union(directories)
        if includesMetadata {
            expected.formUnion(try pinnedReceipt(for: root.lastPathComponent).files.keys)
            expected.insert("installation.json")
        }
        var actual = Set<String>()
        var enumerationError: Error?
        guard let enumeration = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [],
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw MagicWineError.setup("Cannot enumerate DXMT component: \(root.path).")
        }
        let prefix = root.standardizedFileURL.path + "/"
        for case let entry as URL in enumeration {
            guard entry.standardizedFileURL.path.hasPrefix(prefix) else { throw MagicWineError.setup("Escaping DXMT payload path.") }
            let name = String(entry.standardizedFileURL.path.dropFirst(prefix.count))
            guard expected.contains(name) else { throw MagicWineError.setup("Unexpected DXMT payload: \(name).") }
            if directories.contains(name) { try fs.requireDirectory(entry) } else { try requireFile(entry) }
            actual.insert(name)
        }
        if let enumerationError { throw enumerationError }
        guard actual == expected else { throw MagicWineError.setup("Missing DXMT payload: \(expected.subtracting(actual).sorted().joined(separator: ", ")).") }
        for name in payloadNames where name.hasSuffix(".dll") {
            try PEInspector.validateDLL(root.appendingPathComponent(name),
                                        machine: name.hasPrefix("i386-") ? PEInspector.i386 : PEInspector.amd64,
                                        fs: fs, maximum: peMaximum)
        }
        let nativeName = "x86_64-unix/winemetal.so"
        let native = try inspectMachO(root.appendingPathComponent(nativeName))
        guard native.fileType == 6, native.minimumOS == 0x000f0000,
              native.dependencies.contains("@rpath/winemac.so"), native.dependencies.contains("@rpath/ntdll.so"),
              native.exports.contains("___wine_unix_call_funcs"), native.exports.contains("___wine_unix_call_wow64_funcs") else {
            throw MagicWineError.setup("DXMT winemetal.so has incompatible native linkage, deployment target or Wine/WoW64 entry points.")
        }
    }

    private static func validateManagedParents(_ paths: ApplicationPaths) throws {
        guard paths.root.isFileURL else { throw MagicWineError.setup("DXMT requires a local data directory.") }
        try fs.requireDirectory(paths.root)
        try fs.requireDirectory(paths.componentsDirectory)
    }

    private static func validateRoot(_ root: URL) throws {
        let expectedReceipt = try pinnedReceipt(for: root.lastPathComponent)
        let expectedFiles = expectedReceipt.files
        try validatePayloadLayout(at: root, includesMetadata: true)
        let receiptData = try fs.read(root.appendingPathComponent("installation.json"), maximum: 65_536)
        let receipt: Receipt
        do { receipt = try JSONDecoder().decode(Receipt.self, from: receiptData) }
        catch { throw MagicWineError.setup("DXMT installation receipt is malformed: \(error.localizedDescription)") }
        guard receipt == expectedReceipt else { throw MagicWineError.setup("DXMT receipt does not match the pinned component and file checksums.") }
        try cache.verify(root, names: Array(expectedFiles.keys) + ["installation.json", ""] + directories.sorted(), fs: fs,
                         rehash: false, changed: .setup("DXMT component changed during validation; nothing was adopted.")) {
            for (name, expected) in expectedFiles {
                guard try fs.sha256(root.appendingPathComponent(name), maximum: maximum(for: name)) == expected else {
                    throw MagicWineError.setup("DXMT component changed or is corrupted: \(name). Restore Standard and reinstall this component; cached files were left untouched.")
                }
            }
        }
    }

    static func writeReceipt(at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pinnedReceipt(for: root.lastPathComponent))
            .write(to: root.appendingPathComponent("installation.json"), options: .atomic)
    }

    static func publish(_ component: URL, paths: ApplicationPaths) throws -> URL {
        try validateManagedParents(paths)
        try Task.checkCancellation()
        let destination = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
        if try fs.publish(component, to: destination) { return destination }
        try validateRoot(destination)
        try Task.checkCancellation()
        return destination
    }

    /// Thin x86_64 only, with exports, within DXMT's 64 MiB file limit.
    static func inspectMachO(_ url: URL) throws -> MachOInspector.Image {
        try MachOInspector.inspect(url, fs: fs, maximum: 64 * 1_048_576, universal: false, exports: true)
    }
}
