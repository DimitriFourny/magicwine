import CryptoKit
import Darwin
import Foundation

/// The native macOS fork is deliberately pinned: these DLLs are not interchangeable
/// with upstream Vulkan-only DXVK or Gcenx's Wine builtin DLL package.
enum DXVKInstallation {
    static let componentID = "dxvk-macos-1.10.3-magicwine.1"
    static let version = "1.10.3-magicwine.1"
    static let notice = "DXVK — Experimental uses MagicWine's unsigned, altered build of Gcenx's public 1.10.3-based macOS DXVK fork for Direct3D 10/11 only. The native D3D11 implementation rejects unsupported queries instead of reporting fabricated counters. It does not provide Direct3D 9 or 12, anti-cheat compatibility, or proprietary D3DMetal/GPTK binaries. The curated SHA-256 pin identifies the bundled package; it is not malware verification. MagicWine does not remove DXVK quarantine attributes or modify global Wine files."
    static let archiveRoot = "dxvk-macos-1.10.3-magicwine.1"
    static let source = "bundled:Sources/MagicWineCore/Resources/dxvk-macos-1.10.3-magicwine.1.tar.gz"
    static let archiveSHA256 = "88c1664e348c06c27469ef9acc8704a26e998835f9110281ffec6a96b4b26d18"
    private static let repository = "https://github.com/Gcenx/DXVK-macOS"
    private static let sourceCommit = "8f1e28deed3ad30802f7e1bdff428ec14e6e7817"
    private static let sourceArchiveSHA256 = "b3fc4a0415b3e4cdfb40497bec191c10f183ec2eb498950aa1f638f176cb996b"
    private static let upstreamLicenseSource = "https://github.com/doitsujin/dxvk/blob/v1.10.3/LICENSE"
    private static let forkLicenseSource = "https://github.com/Gcenx/DXVK-macOS/blob/\(sourceCommit)/LICENSE"
    private static let dllNames = ["d3d10core.dll", "d3d11.dll"]
    private static let dependencyNoticeName = "LICENSE-DXVK-DEPENDENCIES.txt"
    private static let dependencyNoticeSHA256 = "077bb8f90c2e8dc662cefa54c77309ee5cbee3b4b03bdd5b47ebb14f594b7bb9"

    // Independently recorded from the pinned archive. A forged receipt cannot bless
    // different binaries, even if its archive checksum claims to match our pin.
    private static let payloadDigests = [
        "dxvk.conf": "0e9e39c27db318a8efe787380b09dae1676f0344101ec37dbb78bfb282991bf2",
        "x32/d3d10core.dll": "2ba107be7ff7ad6236117f2f68a842569ef0fe96ddf7ed30d6ee41521ba24276",
        "x32/d3d11.dll": "c6786019a36b80ae15f6dd51aca1780f7c5e161553a5b1dc979f3796bfb06b64",
        "x64/d3d10core.dll": "890e26f26a37adc97ef9711c82baaec815c99bcc256115f3c28c92a5d85306b7",
        "x64/d3d11.dll": "3384ad1538fd53cc9db5e88ac4c7a18f93ce9ebe2b37bb1a91262b9ffb719d61",
    ]

    private static let licenseTerms = """
                              zlib/libpng license

    This software is provided 'as-is', without any express or implied
    warranty. In no event will the authors be held liable for any damages
    arising from the use of this software.

    Permission is granted to anyone to use this software for any purpose,
    including commercial applications, and to alter it and redistribute it
    freely, subject to the following restrictions:

    – The origin of this software must not be misrepresented; you must not
      claim that you wrote the original software. If you use this software
      in a product, an acknowledgment in the product documentation would be
      appreciated but is not required.

    – Altered source versions must be plainly marked as such, and must not
      be misrepresented as being the original software.

    – This notice may not be removed or altered from any source distribution.
    """
    private static let upstreamLicense = """
    Copyright (c) 2017-2021 Philip Rebohle
                      Copyright (c) 2019-2021 Joshua Ashton

    \(licenseTerms)

    """
    private static let forkLicense = """
    Copyright (c) 2017 Philip Rebohle
                      Copyright (c) 2019 Joshua Ashton
                      Copyright (c) 2019 Robin Kertels
                      Copyright (c) 2023 Jeffrey Ellison

    \(licenseTerms)

    """
    private static let provenance = """
    MagicWine experimental native DXVK component
    Component: \(componentID)
    Version: \(version)
    Package source: \(source)
    Archive SHA-256: \(archiveSHA256)
    Checksum authority: MagicWine curated pin (not an upstream signature)
    Fork source: \(repository)
    Fork source commit: \(sourceCommit)
    Source archive: https://codeload.github.com/Gcenx/DXVK-macOS/tar.gz/\(sourceCommit)
    Source archive SHA-256: \(sourceArchiveSHA256)
    MagicWine build recipe: scripts/build-dxvk.sh
    MagicWine source alteration: patches/dxvk-pipeline-statistics.patch
    Build tools: MinGW-w64 14.0.0_3 / GCC 16.2.0, Meson 1.12.1,
    glslang 16.6.0; release native DLLs with static C/C++ runtimes.
    Dependency notices: \(dependencyNoticeName), SHA-256 \(dependencyNoticeSHA256)
    Upstream source: https://github.com/doitsujin/dxvk/tree/v1.10.3
    Upstream zlib/libpng attribution: \(upstreamLicenseSource)
    macOS fork zlib/libpng attribution: \(forkLicenseSource)

    DXVK was created by Philip Rebohle and its contributors. This is MagicWine's
    altered build of the Gcenx macOS/async fork, not an original upstream or
    Gcenx distribution. MagicWine changes native D3D11Device::CreateQuery1 to
    reject unsupported PIPELINE_STATISTICS queries with E_INVALIDARG and a
    null output before returning validation-only S_FALSE. No query interceptor,
    proxy, invented counters, or newly advertised features are included.
    The bundled native x32/x64 d3d10core.dll and d3d11.dll and dxvk.conf are
    installed unchanged. No d3d9.dll or dxgi.dll is included; DXGI stays Wine
    builtin. The receipt records all payload and attribution checksums.
    \(notice)

    """
    private static let attributionFiles = [
        "LICENSE-DXVK.txt": upstreamLicense,
        "LICENSE-DXVK-macOS.txt": forkLicense,
        "PROVENANCE.txt": provenance,
    ]

    private struct Receipt: Codable, Equatable {
        let schema: Int
        let componentID: String
        let version: String
        let source: String
        let archiveSHA256: String
        let repository: String
        let upstreamLicenseSource: String
        let forkLicenseSource: String
        let files: [String: String]
    }

    private static var expectedReceipt: Receipt {
        var metadataDigests = attributionFiles.mapValues { digest(Data($0.utf8)) }
        metadataDigests[dependencyNoticeName] = dependencyNoticeSHA256
        return Receipt(schema: 1, componentID: componentID, version: version,
                       source: source, archiveSHA256: archiveSHA256, repository: repository,
                       upstreamLicenseSource: upstreamLicenseSource, forkLicenseSource: forkLicenseSource,
                       files: payloadDigests.merging(metadataDigests) { original, _ in original })
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
        guard paths.root.isFileURL else {
            throw MagicWineError.setup("DXVK installation requires a local MagicWine data directory.")
        }
        // Reject existing links before prepare can create any child directories.
        if try exists(paths.root) {
            try requireDirectory(paths.root)
            if try exists(paths.componentsDirectory) { try requireDirectory(paths.componentsDirectory) }
        }
        try paths.prepare()
        try validateManagedParents(paths)
        let logURL = paths.logsDirectory.appendingPathComponent("dxvk-install-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path,
              contents: Data((provenance + "\n").utf8), attributes: [.posixPermissions: 0o600]) else {
            throw MagicWineError.setup("Cannot create DXVK installation log: \(logURL.path)")
        }
        let stage = paths.componentsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        do {
            let destination = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
            if try exists(destination) {
                progress?(.verifying)
                try validateRoot(destination, rehash: false)
                try Task.checkCancellation()
                return destination
            }
            progress?(.verifying)
            guard let bundledArchive = Bundle.module.url(forResource: archiveRoot, withExtension: "tar.gz") else {
                throw MagicWineError.setup("The bundled DXVK package is missing. Reinstall this MagicWine build; no component was installed.")
            }
            try requireFile(bundledArchive)
            let archive = stage.appendingPathComponent("dxvk.tar.gz")
            try FileManager.default.copyItem(at: bundledArchive, to: archive)
            try preserveQuarantine(from: bundledArchive, to: archive)
            try Task.checkCancellation()
            let hashing = Task.detached(priority: .utility) { try hash(archive, maximum: 64 * 1_048_576) }
            let checksum = try await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }
            guard checksum == archiveSHA256 else {
                throw MagicWineError.setup("DXVK archive SHA-256 mismatch. No component was installed.")
            }
            try Task.checkCancellation()
            let listing = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-tf", archive.path],
                paths: paths, name: "dxvk-archive-list", timeout: 60)
            let verbose = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-tvf", archive.path],
                paths: paths, name: "dxvk-archive-types", timeout: 60)
            let entries = try logRows(listing.logURL)
            let types = try logRows(verbose.logURL).compactMap(\.first)
            try validateArchiveMembers(entries, types: types)
            progress?(.installing)
            let extraction = stage.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
            // bsdtar's default link/traversal protections remain enabled. The
            // preflight additionally forbids every link and non-pinned member.
            _ = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-xf", archive.path,
                "-C", extraction.path, "--no-same-owner", "--no-same-permissions"],
                paths: paths, name: "dxvk-archive-extract", timeout: 180)
            let component = extraction.appendingPathComponent(archiveRoot, isDirectory: true)
            try validatePayloadLayout(at: component)
            for (name, contents) in attributionFiles {
                try Data(contents.utf8).write(to: component.appendingPathComponent(name), options: .atomic)
            }
            guard let dependencyNotice = Bundle.module.url(forResource: "LICENSE-DXVK-DEPENDENCIES", withExtension: "txt") else {
                throw MagicWineError.setup("The bundled DXVK dependency notices are missing. Reinstall this MagicWine build.")
            }
            try requireFile(dependencyNotice)
            try FileManager.default.copyItem(at: dependencyNotice,
                                            to: component.appendingPathComponent(dependencyNoticeName))
            try writeReceipt(at: component)
            try preserveQuarantine(from: archive, to: component)
            try validateRoot(component, rehash: true)
            try validateManagedParents(paths)
            try Task.checkCancellation()
            return try publish(component, paths: paths)
        } catch {
            let handle = try? FileHandle(forWritingTo: logURL)
            _ = try? handle?.seekToEnd()
            try? handle?.write(contentsOf: Data(("Failure: \(error.localizedDescription)\n").utf8))
            try? handle?.close()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw MagicWineError.setup("DXVK installation failed: \(error.localizedDescription)\nInstallation log: \(logURL.path)")
        }
    }

    static func validate(componentID requested: String, paths: ApplicationPaths) throws -> URL {
        guard requested == componentID else {
            throw MagicWineError.setup("This bottle selects an older or unsupported DXVK component (\(requested)). Create a new bottle and enable DXVK to use \(componentID). In-place component updates are not supported. Choose Standard to restore this bottle's original graphics files.")
        }
        try validateManagedParents(paths)
        let root = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
        try validateRoot(root, rehash: false)
        return root
    }

    private static func validateManagedParents(_ paths: ApplicationPaths) throws {
        guard paths.root.isFileURL,
              try inspect(paths.root).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              try inspect(paths.componentsDirectory).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw MagicWineError.setup("DXVK components must be inside ordinary MagicWine root and Components directories, not symbolic links.")
        }
    }

    private static func validateRoot(_ root: URL, rehash: Bool) throws {
        try validatePayloadLayout(at: root, includesMetadata: true)
        let receiptURL = root.appendingPathComponent("installation.json")
        let receiptData = try boundedFile(receiptURL, maximum: 65_536)
        let receipt: Receipt
        do { receipt = try JSONDecoder().decode(Receipt.self, from: receiptData) }
        catch { throw MagicWineError.setup("The DXVK installation receipt is malformed: \(error.localizedDescription)") }
        guard receipt == expectedReceipt else {
            throw MagicWineError.setup("The DXVK installation receipt does not match the pinned component, source, license, or file checksums.")
        }
        let before = try stamps(at: root, names: Array(receipt.files.keys) + ["installation.json", "", "x32", "x64"])
        if !rehash && cache.matches(before, at: root) { return }
        for (name, expected) in receipt.files {
            guard try hash(root.appendingPathComponent(name), maximum: 32 * 1_048_576) == expected else {
                throw MagicWineError.setup("The DXVK component was changed or corrupted (SHA-256 mismatch): \(name). Restore Standard, move this cached component out of Components, then enable DXVK again. Component: \(root.path)")
            }
        }
        let after = try stamps(at: root, names: Array(before.keys))
        guard before == after else {
            throw MagicWineError.setup("The DXVK component changed during validation. No component was adopted.")
        }
        cache.remember(after, at: root)
    }

    static func validateArchiveMembers(_ entries: [String], types: [Character]) throws {
        let directories = Set([archiveRoot, archiveRoot + "/x32", archiveRoot + "/x64"])
        let files = Set(payloadDigests.keys.map { archiveRoot + "/" + $0 })
        let normalized = entries.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        guard entries.count == directories.count + files.count,
              types.count == entries.count,
              Set(normalized) == directories.union(files),
              entries.allSatisfy({ !$0.hasSuffix("/") || directories.contains(String($0.dropLast())) }),
              Set(normalized).count == normalized.count else {
            throw MagicWineError.setup("The DXVK archive contains missing, duplicate, unsafe, or unexpected paths.")
        }
        for (entry, type) in zip(normalized, types) {
            guard directories.contains(entry) ? type == "d" : type == "-" else {
                throw MagicWineError.setup("The DXVK archive contains a symbolic link, hard link, or unsupported member: \(entry).")
            }
        }
    }

    static func validatePayloadLayout(at root: URL, includesMetadata: Bool = false) throws {
        try requireDirectory(root)
        var expected = Set(payloadDigests.keys)
        expected.formUnion(["x32", "x64"])
        if includesMetadata {
            expected.formUnion(attributionFiles.keys)
            expected.formUnion(["installation.json", dependencyNoticeName])
        }
        var actual = Set<String>()
        var enumerationError: Error?
        guard let enumeration = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [],
            options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw MagicWineError.setup("Cannot enumerate the DXVK component: \(root.path)")
        }
        let base = root.standardizedFileURL.path + "/"
        for case let entry as URL in enumeration {
            guard entry.standardizedFileURL.path.hasPrefix(base) else {
                throw MagicWineError.setup("The DXVK component contains an escaping path: \(entry.path)")
            }
            let name = String(entry.standardizedFileURL.path.dropFirst(base.count))
            guard expected.contains(name) else {
                throw MagicWineError.setup("The DXVK component contains an unexpected file: \(name).")
            }
            if name == "x32" || name == "x64" { try requireDirectory(entry) }
            else { try requireFile(entry) }
            actual.insert(name)
        }
        if let enumerationError { throw enumerationError }
        guard actual == expected else {
            let missing = expected.subtracting(actual).sorted().joined(separator: ", ")
            throw MagicWineError.setup("The DXVK component is incomplete. Missing files: \(missing).")
        }
        for (architecture, machine) in [("x32", UInt16(0x014c)), ("x64", UInt16(0x8664))] {
            for name in dllNames { try validatePE(root.appendingPathComponent("\(architecture)/\(name)"), machine: machine) }
        }
    }

    static func validatePE(_ url: URL, machine: UInt16) throws {
        try requireFile(url)
        let handle = try openFile(url)
        defer { try? handle.close() }
        let dos = try handle.read(upToCount: 64) ?? Data()
        guard dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else {
            throw MagicWineError.setup("The DXVK DLL is not a PE image: \(url.lastPathComponent).")
        }
        let offset = dos[60..<64].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        let size = try inspect(url).st_size
        guard offset >= 64, UInt64(offset) + 26 <= UInt64(max(0, size)) else {
            throw MagicWineError.setup("The DXVK DLL has an invalid PE header offset: \(url.path).")
        }
        try handle.seek(toOffset: UInt64(offset))
        let header = try handle.read(upToCount: 26) ?? Data()
        guard header.count == 26, Array(header[0..<4]) == [0x50, 0x45, 0, 0] else {
            throw MagicWineError.setup("The DXVK DLL has an invalid PE signature: \(url.path).")
        }
        let actual = UInt16(header[4]) | UInt16(header[5]) << 8
        let characteristics = UInt16(header[22]) | UInt16(header[23]) << 8
        let optionalSize = UInt16(header[20]) | UInt16(header[21]) << 8
        let magic = UInt16(header[24]) | UInt16(header[25]) << 8
        guard actual == machine, characteristics & 0x2000 != 0, optionalSize >= 2,
              UInt64(offset) + 24 + UInt64(optionalSize) <= UInt64(size),
              magic == (machine == 0x014c ? 0x010b : 0x020b) else {
            throw MagicWineError.setup("The DXVK DLL has the wrong PE architecture or is not a native DLL: \(url.path) (expected \(String(machine, radix: 16)), found \(String(actual, radix: 16))).")
        }
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
            do {
                try validateRoot(destination, rehash: true)
                try Task.checkCancellation()
                return destination
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw MagicWineError.setup("Another DXVK installation occupies the pinned component path but cannot be safely reused. Existing files were left untouched: \(error.localizedDescription)")
            }
        }
        throw MagicWineError.setup("Cannot atomically publish the DXVK component; existing files were left untouched: \(String(cString: strerror(code))).")
    }

    static func preserveQuarantine(from archive: URL, to root: URL) throws {
        let name = "com.apple.quarantine"
        let size = archive.path.withCString { getxattr($0, name, nil, 0, 0, XATTR_NOFOLLOW) }
        if size < 0 {
            guard errno == ENOATTR else { throw pathError("inspect package quarantine on", archive) }
            return
        }
        guard size <= 65_536 else { throw MagicWineError.setup("DXVK package quarantine metadata exceeds its safety limit.") }
        var data = Data(count: size)
        let received = data.withUnsafeMutableBytes { bytes in
            archive.path.withCString { getxattr($0, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
        }
        guard received == size else { throw pathError("read package quarantine on", archive) }
        let result = data.withUnsafeBytes { bytes in
            root.path.withCString { setxattr($0, name, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
        }
        guard result == 0 else { throw pathError("preserve package quarantine on", root) }
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
            throw MagicWineError.setup("The DXVK path must be an ordinary directory, not a symbolic link: \(url.path).")
        }
    }

    private static func requireFile(_ url: URL) throws {
        let status = try inspect(url)
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_nlink == 1,
              status.st_size > 0, status.st_size <= 32 * 1_048_576 else {
            throw MagicWineError.setup("The DXVK file must be a nonempty ordinary file without symbolic/hard links and within the 32 MiB safety limit: \(url.path).")
        }
    }

    private static func boundedFile(_ url: URL, maximum: Int) throws -> Data {
        try requireFile(url)
        let handle = try openFile(url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw MagicWineError.setup("The DXVK receipt exceeds its inspection limit.") }
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
            guard bytes <= maximum else { throw MagicWineError.setup("DXVK file exceeds its hashing safety limit: \(url.path).") }
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
            throw MagicWineError.setup("The DXVK file changed or is not an ordinary non-hard-linked file: \(url.path).")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func pathError(_ operation: String, _ url: URL) -> MagicWineError {
        let code = errno
        return .setup("Cannot \(operation) DXVK path \(url.path): \(String(cString: strerror(code))).")
    }
}
