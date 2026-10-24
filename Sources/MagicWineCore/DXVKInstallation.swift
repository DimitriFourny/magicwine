import Darwin
import Foundation

/// The native macOS fork is deliberately pinned: these DLLs are not interchangeable
/// with upstream Vulkan-only DXVK or Gcenx's Wine builtin DLL package.
enum DXVKInstallation {
    static let componentID = "dxvk-macos-1.10.3-magicwine.2"
    static let version = "1.10.3-magicwine.2"
    static let notice = "DXVK — Experimental uses MagicWine's unsigned, altered build of Gcenx's public 1.10.3-based macOS DXVK fork for Direct3D 9/10/11. D3D9 enables geometry shaders and shader cull distances only when the Vulkan driver supports them; geometry-dependent operations remain driver-limited. Unsupported pipeline-statistics queries stay unavailable, matching CrossOver compatibility behavior without fabricated counters; games that wait for those counters may stall. It does not provide Direct3D 12, anti-cheat compatibility, or proprietary D3DMetal/GPTK binaries. DXGI stays Wine builtin. The curated SHA-256 pin identifies the bundled package; it is not malware verification. MagicWine does not remove DXVK quarantine attributes or modify global Wine files."
    static let archiveRoot = "dxvk-macos-1.10.3-magicwine.2"
    static let source = "bundled:Sources/MagicWineCore/Resources/dxvk-macos-1.10.3-magicwine.2.tar.gz"
    static let archiveSHA256 = "c06d15ed8bde38bc9fa9c22d8cb823a6904cc0d48fb967f3b43dd55b575458f7"
    private static let repository = "https://github.com/Gcenx/DXVK-macOS"
    private static let sourceCommit = "8f1e28deed3ad30802f7e1bdff428ec14e6e7817"
    private static let sourceArchiveSHA256 = "b3fc4a0415b3e4cdfb40497bec191c10f183ec2eb498950aa1f638f176cb996b"
    private static let upstreamLicenseSource = "https://github.com/doitsujin/dxvk/blob/v1.10.3/LICENSE"
    private static let forkLicenseSource = "https://github.com/Gcenx/DXVK-macOS/blob/\(sourceCommit)/LICENSE"
    private static let dependencyNoticeName = "LICENSE-DXVK-DEPENDENCIES.txt"
    private static let dependencyNoticeSHA256 = "f0ee2e0aae2a9e8871deb7f638a4531b0c738e9c2ae0875dd3263f962d60dc41"

    // Independently recorded from the pinned archive. A forged receipt cannot bless
    // different binaries, even if its archive checksum claims to match our pin.
    private static let payloadDigests = [
        "dxvk.conf": "0e9e39c27db318a8efe787380b09dae1676f0344101ec37dbb78bfb282991bf2",
        "x32/d3d9.dll": "394e3b1234119bfeab76d7963a3b7b7f8b542ce03e83f001ccd5d03967f3504a",
        "x32/d3d10core.dll": "293a29b8f830bcf68a7b7d090f01e157cd685d686c6a7ed50f2a3d643dc5ea89",
        "x32/d3d11.dll": "e6e94fadcd29072d33dc2007644f5b142729c370bea6c4e5bf22c07ab2876cfd",
        "x64/d3d9.dll": "b3a7253b179c14db93d11791002c9cf45b8404d1044acf9917e4a697a67b9d58",
        "x64/d3d10core.dll": "42fb5af68ac3eb12d1090980c03e2567fadf4e252fd05a8a3716f2e9ea4196f8",
        "x64/d3d11.dll": "4015f988856da69e9b4a1007f796de0c5de56c1ce0b49d7840b78ef84790a41b",
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
    MagicWine source alterations: patches/dxvk-pipeline-statistics.patch,
    patches/dxvk-d3d10-device.patch, patches/dxvk-d3d9-macos.patch
    Build tools: MinGW-w64 14.0.0_3 / GCC 16.2.0, Meson 1.12.1,
    glslang 16.6.0; release native DLLs with static C/C++ runtimes.
    Dependency notices: \(dependencyNoticeName), SHA-256 \(dependencyNoticeSHA256)
    Upstream source: https://github.com/doitsujin/dxvk/tree/v1.10.3
    Upstream zlib/libpng attribution: \(upstreamLicenseSource)
    macOS fork zlib/libpng attribution: \(forkLicenseSource)

    DXVK was created by Philip Rebohle and its contributors. This is MagicWine's
    altered build of the Gcenx macOS/async fork, not an original upstream or
    Gcenx distribution. When Vulkan pipelineStatisticsQuery is unavailable,
    MagicWine's D3D11Query accepts creation and preserves Begin/End validation,
    but GetData returns S_FALSE without writing counters or creating an
    unsupported Vulkan query pool. Supported drivers retain real GPU queries.
    This matches CrossOver's observed unavailable-results compatibility behavior
    without falsely advertising Vulkan features or including CrossOver binaries.
    D3D10CoreCreateDevice delegates adapter/feature-level validation to DXVK's
    D3D11CoreCreateDevice instead of rejecting devices based on WineD3D's
    unrelated CheckInterfaceSupport result.
    The D3D9 patch removes an obsolete dummy resource-manager typedef that
    conflicts with modern MinGW's definition. It enables Vulkan geometryShader
    and shaderCullDistance only when supported by the device, instead of
    unconditionally requesting features unavailable in the managed MoltenVK.
    It does not advertise new features; geometry-dependent D3D9 operations
    remain limited by driver support.
    The bundled native x32/x64 d3d9.dll, d3d10core.dll, d3d11.dll and dxvk.conf
    are installed unchanged. No dxgi.dll is included; DXGI stays Wine builtin.
    The receipt records all payload and attribution checksums.
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
        var metadataDigests = attributionFiles.mapValues { SecureFS.digest(Data($0.utf8)) }
        metadataDigests[dependencyNoticeName] = dependencyNoticeSHA256
        return Receipt(schema: 1, componentID: componentID, version: version,
                       source: source, archiveSHA256: archiveSHA256, repository: repository,
                       upstreamLicenseSource: upstreamLicenseSource, forkLicenseSource: forkLicenseSource,
                       files: payloadDigests.merging(metadataDigests) { original, _ in original })
    }

    // Retained older components, each validated against its own receipt (payload and
    // attribution pins). Bottles pinned to them keep launching and can be updated in
    // place. When the current pin changes, add the outgoing `expectedReceipt` here as a
    // literal if its prefix footprint is unchanged; otherwise it stays unsupported.
    private static let retainedReceipts: [Receipt] = []

    static var retainedComponentIDs: [String] { retainedReceipts.map(\.componentID) }

    private static func pinnedReceipt(for requested: String) throws -> Receipt {
        if requested == componentID { return expectedReceipt }
        guard let receipt = retainedReceipts.first(where: { $0.componentID == requested }) else {
            throw MagicWineError.setup("This bottle selects an older or unsupported DXVK component (\(requested)). Choose Standard to restore this bottle's original graphics files, then enable DXVK again to use \(componentID).")
        }
        return receipt
    }

    private static let fs = SecureFS(prefix: "DXVK: ")
    private static let fileMaximum = 32 * 1_048_576
    private static let cache = SecureFS.ValidationCache()

    static func install(paths: ApplicationPaths,
                        progress: (@Sendable (GraphicsSetupProgress) -> Void)? = nil) async throws -> URL {
        try Task.checkCancellation()
        guard paths.root.isFileURL else {
            throw MagicWineError.setup("DXVK installation requires a local MagicWine data directory.")
        }
        // Reject existing links before prepare can create any child directories.
        if try fs.exists(paths.root) {
            try fs.requireDirectory(paths.root)
            if try fs.exists(paths.componentsDirectory) { try fs.requireDirectory(paths.componentsDirectory) }
        }
        try paths.prepare()
        try validateManagedParents(paths)
        // Held open for the whole install so retention never removes it meanwhile.
        let log = try ProcessLogFile.create(in: ProcessLogs.libraryDirectory(paths: paths), operation: "dxvk-install")
        defer { log.close() }
        log.write(Data((provenance + "\n").utf8))
        let logURL = log.url
        let stage = paths.componentsDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        do {
            let destination = paths.componentsDirectory.appendingPathComponent(componentID, isDirectory: true)
            if try fs.exists(destination) {
                progress?(.verifying)
                try validateRoot(destination, rehash: false)
                try Task.checkCancellation()
                return destination
            }
            progress?(.verifying)
            guard let bundledArchive = Bundle.module.url(forResource: archiveRoot, withExtension: "tar.gz") else {
                throw MagicWineError.setup("The bundled DXVK package is missing. Reinstall this MagicWine build; no component was installed.")
            }
            try fs.requireFile(bundledArchive, maximum: fileMaximum)
            let archive = stage.appendingPathComponent("dxvk.tar.gz")
            let extraction = try await BundledArchive.extract(bundledArchive, to: archive, sha256: archiveSHA256,
                maximum: 64 * 1_048_576, toolPrefix: "dxvk", paths: paths, fs: fs,
                progress: progress, validateMembers: validateArchiveMembers)
            let component = extraction.appendingPathComponent(archiveRoot, isDirectory: true)
            try validatePayloadLayout(at: component)
            for (name, contents) in attributionFiles {
                try Data(contents.utf8).write(to: component.appendingPathComponent(name), options: .atomic)
            }
            guard let dependencyNotice = Bundle.module.url(forResource: "LICENSE-DXVK-DEPENDENCIES", withExtension: "txt") else {
                throw MagicWineError.setup("The bundled DXVK dependency notices are missing. Reinstall this MagicWine build.")
            }
            try fs.requireFile(dependencyNotice, maximum: fileMaximum)
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
        _ = try pinnedReceipt(for: requested)
        try validateManagedParents(paths)
        let root = paths.componentsDirectory.appendingPathComponent(requested, isDirectory: true)
        try validateRoot(root, rehash: false)
        return root
    }

    /// An existence check of the runtime's Vulkan/MoltenVK layout, not a GPU-feature certification.
    static func validateRuntime(_ executable: URL) throws {
        let root = executable.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.appendingPathComponent("lib/libMoltenVK.dylib").path),
              manager.fileExists(atPath: root.appendingPathComponent("lib/wine/x86_64-unix/winevulkan.so").path) else {
            throw MagicWineError.setup("This Wine installation does not provide the Vulkan/MoltenVK layout required by this experimental DXVK backend. Use MagicWine's managed Wine runtime or keep Standard rendering.")
        }
    }

    private static func validateManagedParents(_ paths: ApplicationPaths) throws {
        guard paths.root.isFileURL,
              try fs.fileType(paths.root) == mode_t(S_IFDIR),
              try fs.fileType(paths.componentsDirectory) == mode_t(S_IFDIR) else {
            throw MagicWineError.setup("DXVK components must be inside ordinary MagicWine root and Components directories, not symbolic links.")
        }
    }

    private static func validateRoot(_ root: URL, rehash: Bool) throws {
        let expectedReceipt = try pinnedReceipt(for: root.lastPathComponent)
        try validateLayout(at: root, files: Set(expectedReceipt.files.keys).union(["installation.json"]))
        let receiptURL = root.appendingPathComponent("installation.json")
        let receiptData = try fs.read(receiptURL, maximum: 65_536)
        let receipt: Receipt
        do { receipt = try JSONDecoder().decode(Receipt.self, from: receiptData) }
        catch { throw MagicWineError.setup("The DXVK installation receipt is malformed: \(error.localizedDescription)") }
        guard receipt == expectedReceipt else {
            throw MagicWineError.setup("The DXVK installation receipt does not match the pinned component, source, license, or file checksums.")
        }
        try cache.verify(root, names: Array(receipt.files.keys) + ["installation.json", "", "x32", "x64"], fs: fs, rehash: rehash,
                         changed: .setup("The DXVK component changed during validation. No component was adopted.")) {
            for (name, expected) in receipt.files {
                guard try fs.sha256(root.appendingPathComponent(name), maximum: fileMaximum) == expected else {
                    throw MagicWineError.setup("The DXVK component was changed or corrupted (SHA-256 mismatch): \(name). Restore Standard, move this cached component out of Components, then enable DXVK again. Component: \(root.path)")
                }
            }
        }
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
        var files = Set(payloadDigests.keys)
        if includesMetadata {
            files.formUnion(attributionFiles.keys)
            files.formUnion(["installation.json", dependencyNoticeName])
        }
        try validateLayout(at: root, files: files)
    }

    /// Exactly `files` plus the two architecture directories; every listed PE DLL is checked.
    private static func validateLayout(at root: URL, files: Set<String>) throws {
        try fs.requireDirectory(root)
        let expected = files.union(["x32", "x64"])
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
            if name == "x32" || name == "x64" { try fs.requireDirectory(entry) }
            else { try fs.requireFile(entry, maximum: fileMaximum) }
            actual.insert(name)
        }
        if let enumerationError { throw enumerationError }
        guard actual == expected else {
            let missing = expected.subtracting(actual).sorted().joined(separator: ", ")
            throw MagicWineError.setup("The DXVK component is incomplete. Missing files: \(missing).")
        }
        for name in files.sorted() where name.hasSuffix(".dll") {
            let machine = name.hasPrefix("x32/") ? PEInspector.i386 : PEInspector.amd64
            try PEInspector.validateDLL(root.appendingPathComponent(name), machine: machine, fs: fs, maximum: fileMaximum)
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
        if try fs.publish(component, to: destination) { return destination }
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

    static func preserveQuarantine(from archive: URL, to root: URL) throws {
        try fs.preserveQuarantine(from: archive, to: root)
    }
}
