import CryptoKit
import Darwin
import Foundation

/// Imports user-owned Apple libraries; this module never downloads or licenses them.
/// Layout reference: Apple's evaluation-environment redist/lib (external/ + wine/).
/// Apple's download and governing agreement require the user's Apple Account:
/// https://developer.apple.com/games/game-porting-toolkit/
enum D3DMetalInstallation {
    static let notice = "D3DMetal — Experimental imports your own Apple Game Porting Toolkit evaluation libraries. Obtain them from Apple and accept the agreement accompanying your version yourself; MagicWine neither supplies Apple binaries nor accepts or grants Apple license rights. A framework LICENSE may cover only third-party dependencies, not Apple's software. Requires Apple silicon, Rosetta, macOS 14 or newer (or the imported library's higher minimum), and an x86_64 Wine build with Apple's macdrv_functions graphics bridge ABI; ordinary Wine Stable is not compatible. Only 64-bit Direct3D 11/12 and DXGI are selected. Quarantine and accompanying notices are retained. Content hashes detect later changes, not authenticity, permission to use, or malware. No ray tracing or other optional hardware features are forced."

    private static let framework = "external/D3DMetal.framework"
    private static let bridges = ["d3d11", "d3d12", "dxgi"]
    private static let optionalBridges = ["atidxx64", "nvapi64", "nvngx"]
    private static let maximumFile = 512 * 1_048_576

    private struct Receipt: Codable, Equatable {
        let schema: Int
        let source: String
        let architecture: String
        let minimumMacOS: UInt32
        let files: [String: String]
        let links: [String: String]
    }

    private struct Inventory: Equatable {
        var files: [String: String] = [:]
        var links: [String: String] = [:]
        var minimumMacOS: UInt32 = 14 << 16
    }

    static func supports(componentID: String) -> Bool {
        componentID.hasPrefix("d3dmetal-") && componentID.utf8.count == 73 &&
            componentID.dropFirst(9).utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func install(paths: ApplicationPaths, source: URL,
                        progress: (@Sendable (GraphicsSetupProgress) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        try requireDirectory(source)
        guard paths.root.isFileURL else { throw failure("The managed root must be a local directory.") }
        for directory in [paths.root, paths.componentsDirectory] where FileManager.default.fileExists(atPath: directory.path) {
            try requireDirectory(directory)
        }
        try paths.prepare()
        try requireDirectory(paths.root)
        try requireDirectory(paths.componentsDirectory)
        progress?(.verifying)
        let payload = try sourcePayload(source)
        let original = try inventory(payload)
        try requireMinimumOS(original.minimumMacOS)
        let stage = paths.componentsDirectory.appendingPathComponent(".d3dmetal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        progress?(.installing)
        // Copy only inspected entries. Never recurse through an untrusted symlink.
        for name in original.files.keys.sorted() {
            try Task.checkCancellation()
            let input = payload.appendingPathComponent(name)
            let output = stage.appendingPathComponent(name)
            try requireFile(input)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: input, to: output)
            try requireFile(output)
            try DXVKInstallation.preserveQuarantine(from: input, to: output)
            var parent = input.deletingLastPathComponent()
            while parent.path.hasPrefix(payload.path + "/") {
                try requireDirectory(parent)
                try DXVKInstallation.preserveQuarantine(from: parent, to: output)
                parent.deleteLastPathComponent()
            }
        }
        for (name, target) in original.links.sorted(by: { $0.key < $1.key }) {
            let output = stage.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: output.path, withDestinationPath: target)
            try DXVKInstallation.preserveQuarantine(from: payload.appendingPathComponent(name), to: output)
        }
        // Propagate directory/download quarantine even if it was not attached to each library.
        for name in original.files.keys {
            try DXVKInstallation.preserveQuarantine(from: source, to: stage.appendingPathComponent(name))
            if payload != source { try DXVKInstallation.preserveQuarantine(from: payload, to: stage.appendingPathComponent(name)) }
        }
        try DXVKInstallation.preserveQuarantine(from: source, to: stage)
        guard try inventory(payload) == original, try inventory(stage) == original else {
            throw failure("The input changed during import; no component was published.")
        }
        // Preserve license/readme files beside redist/lib, not just framework dependency notices.
        if payload != source {
            var directory = payload.deletingLastPathComponent()
            while directory.path == source.path || directory.path.hasPrefix(source.path + "/") {
                try requireDirectory(directory)
                try copyNotices(from: directory, to: stage)
                if directory.path == source.path { break }
                directory.deleteLastPathComponent()
            }
        }
        let imported = try inventory(stage)
        let receipt = Receipt(schema: 1, source: "local-user-supplied", architecture: "x86_64",
                              minimumMacOS: imported.minimumMacOS, files: imported.files, links: imported.links)
        let encoded = try encode(receipt)
        let id = "d3dmetal-" + digest(encoded)
        try encoded.write(to: stage.appendingPathComponent("installation.json"), options: .atomic)
        try Task.checkCancellation()
        let destination = paths.componentsDirectory.appendingPathComponent(id, isDirectory: true)
        let result = stage.path.withCString { from in
            destination.path.withCString { renamex_np(from, $0, UInt32(RENAME_EXCL)) }
        }
        if result == 0 { return destination }
        let code = errno
        if code == EEXIST || code == ENOTEMPTY { return try validate(componentID: id, paths: paths) }
        throw failure("Cannot atomically publish the import: \(String(cString: strerror(code))). Existing components were not changed.")
    }

    static func validate(componentID: String, paths: ApplicationPaths) throws -> URL {
        guard supports(componentID: componentID) else { throw failure("Unrecognized component identifier. Choose Standard to restore original graphics.") }
        try requireDirectory(paths.root)
        try requireDirectory(paths.componentsDirectory)
        let root = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
        try validateRoot(root)
        return root
    }

    static func environment(component: URL, showHUD: Bool) throws -> [String: String] {
        try validateRoot(component)
        guard !component.path.contains(":"), !component.path.contains("\n") else {
            throw failure("The component path cannot contain environment search-path separators.")
        }
        let external = component.appendingPathComponent("external").path
        return [
            "WINEDLLPATH": component.appendingPathComponent("wine").path,
            "WINEDLLOVERRIDES": "d3d11,d3d12,dxgi=b",
            "DYLD_LIBRARY_PATH": external + ":" + component.appendingPathComponent(framework + "/Resources").path,
            "DYLD_FRAMEWORK_PATH": external,
            "CX_APPLEGPTK_LIBD3DSHARED_PATH": component.appendingPathComponent("external/libd3dshared.dylib").path,
            "MTL_HUD_ENABLED": showHUD ? "1" : "0",
        ]
    }

    static func validateRuntime(_ executable: URL) throws {
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0, arm64 == 1,
              ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)) else {
            throw failure("Apple silicon and macOS 14 or newer are required.")
        }
        // Resolve the user's selected executable, not any component input. Wine distributions
        // commonly expose bin/wine as an in-bundle symlink to their actual loader.
        _ = try machO(executable.resolvingSymlinksInPath())
        let prefix = executable.deletingLastPathComponent().deletingLastPathComponent()
        let candidates = ["lib/wine/x86_64-unix/winemac.so", "lib64/wine/x86_64-unix/winemac.so"]
        for name in candidates {
            let driver = prefix.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: driver.path),
               (try? machO(driver, requiredExport: "_macdrv_functions")) != nil { return }
        }
        throw failure("This Wine runtime does not export Apple's macdrv_functions bridge ABI. Select a compatible GPTK/Whisky/CrossOver native Wine loader in Settings, then create a new bottle with it; ordinary Wine Stable cannot load these libraries. No runtime files were modified.")
    }

    private static func validateRoot(_ root: URL) throws {
        guard supports(componentID: root.lastPathComponent) else { throw failure("Invalid managed component path.") }
        try requireDirectory(root)
        let data = try bounded(root.appendingPathComponent("installation.json"), maximum: 1_048_576)
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.schema == 1, receipt.source == "local-user-supplied", receipt.architecture == "x86_64",
              "d3dmetal-" + digest(try encode(receipt)) == root.lastPathComponent else {
            throw failure("The receipt does not match its content-addressed directory.")
        }
        let actual = try inventory(root, receiptAllowed: true)
        guard actual.files == receipt.files, actual.links == receipt.links, actual.minimumMacOS == receipt.minimumMacOS else {
            throw failure("The imported libraries or notices changed. Restore Standard; do not reuse this component.")
        }
        try requireMinimumOS(receipt.minimumMacOS)
    }

    private static func requireMinimumOS(_ version: UInt32) throws {
        let required = OperatingSystemVersion(majorVersion: Int(version >> 16),
            minorVersion: Int((version >> 8) & 255), patchVersion: Int(version & 255))
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else {
            throw failure("This payload requires macOS \(required.majorVersion).\(required.minorVersion).\(required.patchVersion) or newer.")
        }
    }

    private static func sourcePayload(_ source: URL) throws -> URL {
        for relative in ["", "redist/lib", "lib"] {
            let root = relative.isEmpty ? source : source.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("external").path),
               FileManager.default.fileExists(atPath: root.appendingPathComponent("wine").path) {
                var current = root
                while current.path != source.path {
                    try requireDirectory(current)
                    current.deleteLastPathComponent()
                }
                try requireDirectory(root)
                return root
            }
        }
        throw failure("Select an extracted evaluation-environment folder containing redist/lib, its lib folder, or an apple_gptk root containing external/ and wine/. Both the Windows and Unix bridges are required.")
    }

    /// Internal for security regressions; validates complete structure before import.
    static func inspectPayload(_ root: URL) throws { _ = try inventory(root) }

    private static func inventory(_ root: URL, receiptAllowed: Bool = false) throws -> Inventory {
        try requireDirectory(root)
        var result = Inventory()
        var directories = Set<String>()
        var enumerationError: Error?
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [],
            errorHandler: { _, error in enumerationError = error; return false }) else { throw failure("Cannot enumerate import.") }
        let base = root.standardizedFileURL.path + "/"
        var total: Int64 = 0
        var count = 0
        for case let item as URL in items {
            try Task.checkCancellation()
            count += 1
            guard count <= 256, item.standardizedFileURL.path.hasPrefix(base) else { throw failure("Unsafe or oversized import tree.") }
            let name = String(item.standardizedFileURL.path.dropFirst(base.count))
            guard safe(name) else { throw failure("Unsafe import path: \(name).") }
            let status = try inspect(item)
            let type = status.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFLNK) {
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                let permitted = name == framework + "/D3DMetal" && target == "Versions/Current/D3DMetal" ||
                    name == framework + "/Resources" && target == "Versions/Current/Resources" ||
                    name == framework + "/Versions/Current" && target == "A"
                guard permitted, item.resolvingSymlinksInPath().path.hasPrefix(root.appendingPathComponent(framework).resolvingSymlinksInPath().path + "/"),
                      FileManager.default.fileExists(atPath: item.path) else {
                    throw failure("Only nonescaping conventional framework links are accepted: \(name).")
                }
                result.links[name] = target
            } else if type == mode_t(S_IFDIR) {
                guard allowedDirectory(name) else { throw failure("Unrecognized directory: \(name).") }
                directories.insert(name)
            } else {
                try requireFile(item)
                if name == "installation.json", receiptAllowed { continue }
                guard allowedFile(name) else { throw failure("Unrecognized file: \(name).") }
                total += status.st_size
                guard total <= 1_073_741_824 else { throw failure("Import exceeds the 1 GiB safety limit.") }
                result.files[name] = try hash(item)
                if name.hasSuffix(".dll") {
                    try DXVKInstallation.validatePE(item, machine: 0x8664)
                    let handle = try openFile(item)
                    defer { try? handle.close() }
                    let header = try handle.read(upToCount: 81) ?? Data()
                    guard header.count == 81, header[64..<81].elementsEqual(Data("Wine builtin DLL\0".utf8)) else {
                        throw failure("Expected an unchanged Wine builtin bridge, not a native replacement: \(name).")
                    }
                }
                if name.hasSuffix(".so") || name.hasSuffix(".dylib") || name.hasSuffix("/D3DMetal") {
                    result.minimumMacOS = max(result.minimumMacOS, try machO(item))
                }
            }
        }
        if let enumerationError { throw enumerationError }
        for bridge in bridges {
            for path in ["wine/x86_64-windows/\(bridge).dll", "wine/x86_64-unix/\(bridge).so"] {
                guard result.files[path] != nil else { throw failure("Missing required bridge: \(path).") }
            }
        }
        for bridge in optionalBridges {
            guard (result.files["wine/x86_64-windows/\(bridge).dll"] != nil) == (result.files["wine/x86_64-unix/\(bridge).so"] != nil) else {
                throw failure("Incomplete optional bridge pair: \(bridge).")
            }
        }
        let versioned = result.files[framework + "/Versions/A/D3DMetal"] != nil
        let binary = framework + (versioned ? "/Versions/A" : "")
        for path in ["external/libd3dshared.dylib", binary + "/D3DMetal", binary + "/Resources/Info.plist",
                     binary + "/Resources/LICENSE", binary + "/Resources/libmetalirconverter.dylib"] {
            guard result.files[path] != nil else { throw failure("Incomplete framework; missing \(path).") }
        }
        if versioned {
            guard result.links[framework + "/D3DMetal"] != nil, result.links[framework + "/Resources"] != nil,
                  result.links[framework + "/Versions/Current"] == "A" else { throw failure("Incomplete framework aliases.") }
        } else if !result.links.isEmpty { throw failure("Unexpected links in a flat framework.") }
        // Reject empty extra directories and mixed flat/versioned representations.
        for directory in directories {
            guard result.files.keys.contains(where: { $0.hasPrefix(directory + "/") }) ||
                  result.links.keys.contains(where: { $0.hasPrefix(directory + "/") }) else { throw failure("Empty unexpected directory: \(directory).") }
        }
        if versioned, result.files[framework + "/D3DMetal"] != nil { throw failure("Ambiguous framework layout.") }
        return result
    }

    private static func allowedDirectory(_ name: String) -> Bool {
        if ["external", "wine", "wine/x86_64-windows", "wine/x86_64-unix", "Notices", framework,
            framework + "/Versions", framework + "/Versions/A"].contains(name) { return true }
        return ["/Resources", "/_CodeSignature", "/Versions/A/Resources", "/Versions/A/_CodeSignature"].contains { name == framework + $0 }
    }

    private static func allowedFile(_ name: String) -> Bool {
        if name == "external/libd3dshared.dylib" { return true }
        if (bridges + optionalBridges).contains(where: { name == "wine/x86_64-windows/\($0).dll" || name == "wine/x86_64-unix/\($0).so" }) { return true }
        if !name.contains("/") { return isNotice(name) }
        if name.hasPrefix("Notices/"), name.split(separator: "/").count == 2 { return isNotice(String(name.dropFirst(8))) }
        for prefix in [framework, framework + "/Versions/A"] {
            if name == prefix + "/D3DMetal" || name == prefix + "/_CodeSignature/CodeResources" { return true }
            if name.hasPrefix(prefix + "/Resources/") {
                let leaf = String(name.dropFirst((prefix + "/Resources/").count))
                return ["Info.plist", "version.plist", "default.metallib", "libmetalirconverter.dylib", "libdxilconv.dylib",
                        "libdxccontainer.dylib", "libdxcompiler.dylib"].contains(leaf) || isNotice(leaf)
            }
        }
        return false
    }

    private static func isNotice(_ name: String) -> Bool {
        guard !name.contains("/"), !name.isEmpty else { return false }
        let lower = name.lowercased()
        return ["license", "licence", "copying", "notice", "readme", "read me", "acknowledg", "software license"].contains { lower.hasPrefix($0) }
    }

    private static func copyNotices(from source: URL, to root: URL) throws {
        for input in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: []) where isNotice(input.lastPathComponent) {
            try requireFile(input)
            let folder = root.appendingPathComponent("Notices", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent(input.lastPathComponent)
            try FileManager.default.copyItem(at: input, to: output)
            try DXVKInstallation.preserveQuarantine(from: input, to: output)
            try DXVKInstallation.preserveQuarantine(from: source, to: output)
        }
    }

    private static func safe(_ name: String) -> Bool {
        !name.contains("\\") && !name.contains(":") && !name.contains("\n") &&
            name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Reads only Mach-O headers/load commands; never loads executable code into MagicWine.
    /// The optional symbol check requires a defined, external nlist entry (not a string match).
    private static func machO(_ url: URL, requiredExport: String? = nil) throws -> UInt32 {
        let handle = try openFile(url)
        defer { try? handle.close() }
        let fileSize = UInt64(try inspect(url).st_size)
        func readAt(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, count <= 16 * 1_048_576, offset <= fileSize, UInt64(count) <= fileSize - offset else { throw failure("Truncated Mach-O: \(url.path).") }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw failure("Truncated Mach-O: \(url.path).") }
            return data
        }
        func u32(_ data: Data, _ index: Int, big: Bool = false) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[index + $1]) << ((big ? 3 - $1 : $1) * 8) }
        }
        let initial = try readAt(0, 8)
        var offset: UInt64 = 0
        var sliceSize = fileSize
        if u32(initial, 0, big: true) == 0xcafebabe {
            let count = Int(u32(initial, 4, big: true))
            guard (1...16).contains(count) else { throw failure("Invalid universal Mach-O architecture table.") }
            let table = try readAt(8, count * 20)
            var found = false
            for i in 0..<count where u32(table, i * 20, big: true) == 0x01000007 {
                guard !found else { throw failure("Duplicate x86_64 Mach-O slice.") }
                found = true
                offset = UInt64(u32(table, i * 20 + 8, big: true))
                sliceSize = UInt64(u32(table, i * 20 + 12, big: true))
            }
            guard found, offset <= fileSize, sliceSize <= fileSize - offset else { throw failure("No valid x86_64 Mach-O slice.") }
        }
        let header = try readAt(offset, 32)
        guard u32(header, 0) == 0xfeedfacf, u32(header, 4) == 0x01000007,
              [UInt32(2), 6, 8].contains(u32(header, 12)) else { throw failure("Expected an x86_64 Mach-O executable/library: \(url.path).") }
        let count = Int(u32(header, 16)), bytes = Int(u32(header, 20))
        guard count > 0, count <= 4096, bytes <= 1_048_576, UInt64(bytes + 32) <= sliceSize else { throw failure("Invalid Mach-O load commands.") }
        let commands = try readAt(offset + 32, bytes)
        var cursor = 0
        var minimum: UInt32 = 0
        var symbolTable: (UInt32, UInt32, UInt32, UInt32)?
        for _ in 0..<count {
            guard cursor + 8 <= bytes else { throw failure("Truncated Mach-O command.") }
            let command = u32(commands, cursor), length = Int(u32(commands, cursor + 4))
            guard length >= 8, length % 4 == 0, length <= bytes - cursor else { throw failure("Invalid Mach-O command size.") }
            if command == 0x32 {
                guard length >= 24, u32(commands, cursor + 8) == 1 else { throw failure("The library is not built for macOS.") }
                minimum = max(minimum, u32(commands, cursor + 12))
            } else if command == 0x24 {
                guard length >= 16 else { throw failure("Invalid macOS minimum-version command.") }
                minimum = max(minimum, u32(commands, cursor + 8))
            } else if command == 2 {
                guard length >= 24 else { throw failure("Invalid Mach-O symbol table.") }
                symbolTable = (u32(commands, cursor + 8), u32(commands, cursor + 12), u32(commands, cursor + 16), u32(commands, cursor + 20))
            }
            cursor += length
        }
        guard cursor == bytes else { throw failure("Inconsistent Mach-O command extent.") }
        if let requiredExport {
            guard let table = symbolTable else { throw failure("Wine's graphics ABI export table is unavailable.") }
            let (symbolsOffset, number, stringsOffset, stringsSize) = table
            guard number <= 1_000_000, UInt64(symbolsOffset) + UInt64(number) * 16 <= sliceSize,
                  UInt64(stringsOffset) + UInt64(stringsSize) <= sliceSize else { throw failure("Wine's graphics ABI export table is unavailable.") }
            let symbols = try readAt(offset + UInt64(symbolsOffset), Int(number) * 16)
            let strings = try readAt(offset + UInt64(stringsOffset), Int(stringsSize))
            let expected = Data((requiredExport + "\0").utf8)
            var found = false
            for i in 0..<Int(number) {
                let start = i * 16, name = Int(u32(symbols, i * 16))
                let type = symbols[start + 4]
                if type & 0xe0 == 0, type & 1 == 1, type & 0x0e == 0x0e,
                   name <= strings.count, expected.count <= strings.count - name,
                   strings[name..<(name + expected.count)].elementsEqual(expected) { found = true; break }
            }
            guard found else { throw failure("Wine does not export \(requiredExport).") }
        }
        return minimum
    }

    private static func inspect(_ url: URL) throws -> stat {
        guard url.isFileURL else { throw failure("Only local filesystem inputs are accepted.") }
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else { throw failure("Cannot inspect \(url.path): \(String(cString: strerror(errno))).") }
        return status
    }

    private static func requireDirectory(_ url: URL) throws {
        guard try inspect(url).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw failure("Expected an ordinary directory, not a link: \(url.path).") }
    }

    private static func requireFile(_ url: URL) throws {
        let status = try inspect(url)
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_nlink == 1,
              status.st_size > 0, status.st_size <= maximumFile else { throw failure("Expected a nonempty regular file without links, at most 512 MiB: \(url.path).") }
    }

    private static func openFile(_ url: URL) throws -> FileHandle {
        try requireFile(url)
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw failure("Cannot safely open \(url.path).") }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              status.st_nlink == 1, status.st_size > 0, status.st_size <= maximumFile else {
            close(descriptor)
            throw failure("File changed while opening: \(url.path).")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func bounded(_ url: URL, maximum: Int) throws -> Data {
        let handle = try openFile(url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw failure("Metadata exceeds its safety limit.") }
        return data
    }

    private static func hash(_ url: URL) throws -> String {
        let handle = try openFile(url)
        defer { try? handle.close() }
        var sha = SHA256()
        var count = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            count += data.count
            guard count <= maximumFile else { throw failure("File grew beyond its safety limit.") }
            sha.update(data: data)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ receipt: Receipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(receipt)
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ message: String) -> MagicWineError { .setup("D3DMetal: " + message) }
}
