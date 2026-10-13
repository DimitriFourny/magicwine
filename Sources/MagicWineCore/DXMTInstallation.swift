import CryptoKit
import Darwin
import Foundation
import Metal

/// v0.80 is the last MIT release. All upstream payload bytes remain unmodified.
/// The isolated GraphicsRuntimeView, not WINEDLLPATH alone, prevents WineD3D fallback.
enum DXMTInstallation {
    static let componentID = "dxmt-v0.80"
    static let archiveRoot = "v0.80"
    static let archiveName = "dxmt-v0.80-builtin"
    static let archiveSHA256 = "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"
    static let source = "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz"
    static let notice = "DXMT — Experimental translates Direct3D 10/11 to Metal, not Direct3D 9/12. This pinned, unmodified MIT-licensed v0.80 package requires macOS 15 or later, an Apple Silicon Metal GPU, Rosetta and compatible Wine. Use Install Wine in Downloads or Settings for MagicWine's managed runtime with the required Metal-view interface. The DXMT package and driver are bundled; no additional DXMT download is needed. Standard graphics remains the default; select DXMT in the bottle's Graphics settings to enable it. A compatible custom Wine runtime may also be used. An isolated process-local loader view prevents runtime WineD3D or winemetal from shadowing DXMT; the shared runtime is never modified by graphics selection. No CrossOver or Apple proprietary binaries are bundled. Quarantine and the original release archive are preserved. Restore Standard before updating a component."
    private static let directories: Set<String> = ["i386-windows", "x86_64-windows", "x86_64-unix"]
    private static let licenseSHA256 = "0acf1ce81dc7bbc0165f2f95ea359f37dc6bbe6546ef9f5feefa33496a942624"
    // Independent pins: a rewritten receipt cannot bless different extracted files.
    // Optional upstream NVAPI/NVNGX are preserved but never overlaid or enabled.
    static let payloadDigests: [String: String] = [
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
    ]
    // This versioned component metadata is immutable. Its original notice is
    // separate from live onboarding text so UI changes cannot invalidate receipts.
    private static let provenance = """
    MagicWine DXMT component: \(componentID)
    Upstream: https://github.com/3Shain/dxmt/tree/589adb780354b461645b29999cefaf533594ee99
    Release archive: \(source)
    Archive SHA-256: \(archiveSHA256)
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
        files["PROVENANCE.txt"] = digest(Data(provenance.utf8))
        return files
    }
    private static var expectedReceipt: Receipt {
        Receipt(schema: 1, componentID: componentID, source: source,
                archiveSHA256: archiveSHA256, files: expectedFiles)
    }
    private struct FileStamp: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = status.st_ctimespec.tv_nsec
        }
    }

    // Process-local adoption cache, never persisted as evidence of integrity. The
    // first adoption hashes every file; inode/size/mtime/ctime changes invalidate it.
    private final class ValidationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: [String: FileStamp]] = [:]

        func matches(_ stamps: [String: FileStamp], at root: URL) -> Bool {
            lock.withLock { entries[root.path] == stamps }
        }

        func remember(_ stamps: [String: FileStamp], at root: URL) {
            lock.withLock { entries[root.path] = stamps }
        }
    }
    private static let cache = ValidationCache()


    static func install(paths: ApplicationPaths,
                        progress: (@Sendable (GraphicsSetupProgress) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard paths.root.isFileURL else { throw MagicWineError.setup("DXMT requires a local data directory.") }
        if try exists(paths.root) {
            try requireDirectory(paths.root)
            if try exists(paths.componentsDirectory) { try requireDirectory(paths.componentsDirectory) }
        }
        try paths.prepare()
        try validateManagedParents(paths)
        let destination = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
        if try exists(destination) {
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
        try FileManager.default.copyItem(at: bundled, to: archive)
        try DXVKInstallation.preserveQuarantine(from: bundled, to: archive)
        let hashing = Task.detached(priority: .utility) { try hash(archive, maximum: 32 * 1_048_576) }
        let checksum = try await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }
        guard checksum == archiveSHA256 else { throw MagicWineError.setup("DXMT archive SHA-256 mismatch; nothing was installed.") }
        let listing = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-tf", archive.path],
            paths: paths, name: "dxmt-archive-list", timeout: 60)
        let verbose = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-tvf", archive.path],
            paths: paths, name: "dxmt-archive-types", timeout: 60)
        try validateArchiveMembers(logRows(listing.logURL), types: logRows(verbose.logURL).compactMap(\.first))
        try Task.checkCancellation()
        progress?(.installing)
        let extraction = stage.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
        _ = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-xf", archive.path, "-C", extraction.path,
            "--no-same-owner", "--no-same-permissions"], paths: paths, name: "dxmt-archive-extract", timeout: 180)
        let component = extraction.appendingPathComponent(archiveRoot, isDirectory: true)
        try validatePayloadLayout(at: component)
        for (name, expected) in payloadDigests {
            guard try hash(component.appendingPathComponent(name), maximum: 32 * 1_048_576) == expected else {
                throw MagicWineError.setup("DXMT upstream payload checksum mismatch: \(name).")
            }
        }
        try FileManager.default.moveItem(at: archive, to: component.appendingPathComponent(archiveName + ".tar.gz"))
        try FileManager.default.copyItem(at: license, to: component.appendingPathComponent("LICENSE-DXMT.txt"))
        try Data(provenance.utf8).write(to: component.appendingPathComponent("PROVENANCE.txt"), options: .atomic)
        try writeReceipt(at: component)
        // Propagate quarantine to every loadable copy, not only its enclosing directory.
        try DXVKInstallation.preserveQuarantine(from: bundled, to: component)
        for name in payloadDigests.keys {
            try DXVKInstallation.preserveQuarantine(from: bundled, to: component.appendingPathComponent(name))
        }
        try validateRoot(component)
        return try publish(component, paths: paths)
    }

    static func validate(componentID requested: String, paths: ApplicationPaths) throws -> URL {
        guard requested == componentID else {
            throw MagicWineError.setup("Unsupported DXMT component \(requested). Restore Standard before selecting the current DXMT component.")
        }
        try validateManagedParents(paths)
        let root = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
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
        try requireDirectory(unix)
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
            try requireDirectory(directory)
            try DXVKInstallation.validatePE(directory.appendingPathComponent("winemac.drv"),
                                            machine: architecture == "i386-windows" ? 0x014c : 0x8664)
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
        try requireDirectory(root)
        let payloadNames = Array(payloadDigests.keys)
        var expected = Set(payloadNames).union(directories)
        if includesMetadata { expected.formUnion(expectedFiles.keys); expected.insert("installation.json") }
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
            if directories.contains(name) { try requireDirectory(entry) } else { try requireFile(entry) }
            actual.insert(name)
        }
        if let enumerationError { throw enumerationError }
        guard actual == expected else { throw MagicWineError.setup("Missing DXMT payload: \(expected.subtracting(actual).sorted().joined(separator: ", ")).") }
        for name in payloadNames where name.hasSuffix(".dll") {
            try DXVKInstallation.validatePE(root.appendingPathComponent(name), machine: name.hasPrefix("i386-") ? 0x014c : 0x8664)
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
        try requireDirectory(paths.root)
        try requireDirectory(paths.componentsDirectory)
    }

    private static func validateRoot(_ root: URL) throws {
        try validatePayloadLayout(at: root, includesMetadata: true)
        let receiptData = try boundedFile(root.appendingPathComponent("installation.json"), maximum: 65_536)
        let receipt: Receipt
        do { receipt = try JSONDecoder().decode(Receipt.self, from: receiptData) }
        catch { throw MagicWineError.setup("DXMT installation receipt is malformed: \(error.localizedDescription)") }
        guard receipt == expectedReceipt else { throw MagicWineError.setup("DXMT receipt does not match the pinned component and file checksums.") }
        let before = try stamps(at: root, names: Array(expectedFiles.keys) + ["installation.json", ""] + directories.sorted())
        if cache.matches(before, at: root) { return }
        for (name, expected) in expectedFiles {
            guard try hash(root.appendingPathComponent(name), maximum: 32 * 1_048_576) == expected else {
                throw MagicWineError.setup("DXMT component changed or is corrupted: \(name). Restore Standard and reinstall this component; cached files were left untouched.")
            }
        }
        let after = try stamps(at: root, names: Array(before.keys))
        guard before == after else { throw MagicWineError.setup("DXMT component changed during validation; nothing was adopted.") }
        cache.remember(after, at: root)
    }

    static func writeReceipt(at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(expectedReceipt).write(to: root.appendingPathComponent("installation.json"), options: .atomic)
    }

    static func publish(_ component: URL, paths: ApplicationPaths) throws -> URL {
        try validateManagedParents(paths)
        try Task.checkCancellation()
        let destination = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
        let result = component.path.withCString { sourcePath in
            destination.path.withCString { renamex_np(sourcePath, $0, UInt32(RENAME_EXCL)) }
        }
        if result == 0 { return destination }
        let code = errno
        if code == EEXIST || code == ENOTEMPTY {
            try validateRoot(destination)
            try Task.checkCancellation()
            return destination
        }
        throw MagicWineError.setup("Cannot atomically publish DXMT; existing files were left untouched: \(String(cString: strerror(code))).")
    }

    struct MachOInfo {
        let fileType: UInt32
        let minimumOS: UInt32?
        let dependencies: Set<String>
        let rpaths: Set<String>
        let exports: Set<String>
    }

    /// Inspect, never dlopen, untrusted native code. A bounded LC_SYMTAB walk
    /// distinguishes real public definitions from imports or embedded strings.
    static func inspectMachO(_ url: URL) throws -> MachOInfo {
        try requireFile(url)
        let handle = try openFile(url)
        defer { try? handle.close() }
        let fileSize = Int(try inspect(url).st_size)
        func bytes(_ offset: Int, _ count: Int) throws -> Data {
            guard offset >= 0, count >= 0, offset <= fileSize, count <= fileSize - offset else {
                throw MagicWineError.setup("Truncated DXMT/Wine Mach-O data: \(url.path).")
            }
            try handle.seek(toOffset: UInt64(offset))
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw MagicWineError.setup("Mach-O changed during inspection: \(url.path).") }
            return data
        }
        func u32(_ data: Data, _ offset: Int) -> UInt32 {
            UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
                UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
        }
        func string(_ data: Data, _ offset: Int, _ end: Int) throws -> String {
            guard offset >= 0, offset < end, end <= data.count,
                  let zero = data[offset..<end].firstIndex(of: 0),
                  let value = String(data: data[offset..<zero], encoding: .utf8) else {
                throw MagicWineError.setup("Malformed Mach-O string: \(url.path).")
            }
            return value
        }
        let header = try bytes(0, 32)
        guard u32(header, 0) == 0xfeedfacf, u32(header, 4) == 0x01000007 else {
            throw MagicWineError.setup("DXMT requires thin x86_64 Mach-O Wine/native libraries: \(url.path).")
        }
        let count = Int(u32(header, 16)), size = Int(u32(header, 20))
        guard count > 0, count <= 4096, size >= count * 8, size <= 1_048_576 else {
            throw MagicWineError.setup("Invalid Mach-O load command bounds: \(url.path).")
        }
        let commands = try bytes(32, size)
        var cursor = 0
        var dependencies = Set<String>(), rpaths = Set<String>()
        var minimumOS: UInt32?
        var symbols: (offset: Int, count: Int, strings: Int, stringSize: Int)?
        for _ in 0..<count {
            guard cursor <= size - 8 else { throw MagicWineError.setup("Truncated Mach-O load command.") }
            let command = u32(commands, cursor), length = Int(u32(commands, cursor + 4))
            guard length >= 8, length % 8 == 0, length <= size - cursor else {
                throw MagicWineError.setup("Invalid Mach-O load command size.")
            }
            switch command {
            case 0x0c, 0x80000018, 0x8000001f:
                guard length >= 24 else { throw MagicWineError.setup("Truncated Mach-O dependency command.") }
                let offset = Int(u32(commands, cursor + 8))
                guard offset >= 24, offset < length else { throw MagicWineError.setup("Invalid Mach-O dependency name.") }
                dependencies.insert(try string(commands, cursor + offset, cursor + length))
            case 0x8000001c:
                guard length >= 16 else { throw MagicWineError.setup("Truncated Mach-O rpath.") }
                let offset = Int(u32(commands, cursor + 8))
                guard offset >= 12, offset < length else { throw MagicWineError.setup("Invalid Mach-O rpath name.") }
                rpaths.insert(try string(commands, cursor + offset, cursor + length))
            case 0x32:
                guard length >= 24, u32(commands, cursor + 8) == 1 else {
                    throw MagicWineError.setup("DXMT requires a macOS Mach-O build target.")
                }
                minimumOS = u32(commands, cursor + 12)
            case 0x24:
                guard length >= 16 else { throw MagicWineError.setup("Truncated Mach-O deployment target.") }
                minimumOS = u32(commands, cursor + 8)
            case 2:
                guard length == 24, symbols == nil else { throw MagicWineError.setup("Invalid Mach-O symbol-table command.") }
                symbols = (Int(u32(commands, cursor + 8)), Int(u32(commands, cursor + 12)),
                           Int(u32(commands, cursor + 16)), Int(u32(commands, cursor + 20)))
            default: break
            }
            cursor += length
        }
        guard cursor == size else { throw MagicWineError.setup("Unexpected trailing Mach-O load command data.") }
        var exports = Set<String>()
        if let symbols {
            guard symbols.count <= 1_048_576, symbols.stringSize <= 16 * 1_048_576 else {
                throw MagicWineError.setup("Mach-O symbols exceed inspection bounds.")
            }
            let table = try bytes(symbols.offset, symbols.count * 16)
            let strings = try bytes(symbols.strings, symbols.stringSize)
            for index in 0..<symbols.count {
                let offset = index * 16, type = table[offset + 4]
                // N_EXT | N_SECT, excluding N_STAB and N_PEXT (hidden) symbols.
                guard type & 0xe0 == 0, type & 0x10 == 0, type & 0x0f == 0x0f else { continue }
                let name = Int(u32(table, offset))
                exports.insert(try string(strings, name, strings.count))
            }
        }
        return MachOInfo(fileType: u32(header, 12), minimumOS: minimumOS,
                         dependencies: dependencies, rpaths: rpaths, exports: exports)
    }
    private static func logRows(_ logURL: URL) throws -> [String] {
        try RuntimeInstallation.boundedLog(logURL, maximum: 1_048_576)
            .components(separatedBy: "\n").dropFirst(2).filter { !$0.isEmpty }
    }

    private static func stamps(at root: URL, names: [String]) throws -> [String: FileStamp] {
        var result: [String: FileStamp] = [:]
        for name in names { result[name] = FileStamp(try inspect(name.isEmpty ? root : root.appendingPathComponent(name))) }
        return result
    }

    private static func exists(_ url: URL) throws -> Bool {
        var status = stat()
        if url.path.withCString({ lstat($0, &status) }) == 0 { return true }
        if errno == ENOENT { return false }
        throw pathError("inspect", url)
    }

    private static func inspect(_ url: URL) throws -> stat {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else { throw pathError("inspect", url) }
        return status
    }

    private static func requireDirectory(_ url: URL) throws {
        guard try inspect(url).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw MagicWineError.setup("The DXMT path must be an ordinary directory, not a symbolic link: \(url.path).")
        }
    }

    private static func requireFile(_ url: URL) throws {
        let status = try inspect(url)
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_nlink == 1,
              status.st_size > 0, status.st_size <= 32 * 1_048_576 else {
            throw MagicWineError.setup("The DXMT file must be a nonempty ordinary file without symbolic/hard links and within the 32 MiB safety limit: \(url.path).")
        }
    }

    private static func boundedFile(_ url: URL, maximum: Int) throws -> Data {
        try requireFile(url)
        let handle = try openFile(url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw MagicWineError.setup("The DXMT receipt exceeds its inspection limit.") }
        return data
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ url: URL, maximum: Int) throws -> String {
        let handle = try openFile(url)
        defer { try? handle.close() }
        var digest = SHA256()
        var bytes = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            bytes += data.count
            guard bytes <= maximum else { throw MagicWineError.setup("DXMT file exceeds its hashing safety limit: \(url.path).") }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func openFile(_ url: URL) throws -> FileHandle {
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw pathError("open without following links", url) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 1, status.st_size > 0 else {
            close(descriptor)
            throw MagicWineError.setup("The DXMT file changed or is not an ordinary non-hard-linked file: \(url.path).")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func pathError(_ operation: String, _ url: URL) -> MagicWineError {
        let code = errno
        return .setup("Cannot \(operation) DXMT path \(url.path): \(String(cString: strerror(code))).")
    }
}
