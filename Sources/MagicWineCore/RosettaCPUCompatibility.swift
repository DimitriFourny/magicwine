import CryptoKit
import Darwin
import Foundation

/// The caller holds GraphicsPrefix.withLock. This single-DLL deployment does not
/// change bottle metadata, Wine's shared runtime, or persistent DLL overrides.
enum RosettaCPUCompatibility {
    static let componentID = "wow64cpu-wine11.0-magicwine.1"
    static let originalSHA256 = "cbbf4d054d5488e19d82ea24e7c280c3408ee43b00fce708d1b559acada9d21e"
    // Independent curated pins, never read from writable bottle metadata.
    private static let bundledDLLSHA256 = "550f8026530ee2ec8ce038c68bcb265972178cea65ab4b10a7c99c375ccfde50"
    private static let bundledSourceSHA256 = "8576e58d0ecaca4045c36742be2eaeec96fb7926208b8372799850b052760b30"
    private static let bundledLicenseSHA256 = "f686a307088beaf3101b564756680f3dd4eb2b04d9e3202a6d0f8123fb116de8"
    static let originalName = "original-wow64cpu.dll"
    static let sourceName = componentID + "-source.tar.gz"
    static let licenseName = "LICENSE-WINE-WOW64CPU.txt"
    private static let dllMaximum = 16 * 1_048_576
    private static let sourceMaximum = 512 * 1_048_576
    private static let licenseMaximum = 1_048_576
    private static var manager: FileManager { .default }

    /// Explicit payload pins keep isolated filesystem tests independent of Wine.
    /// Production constructs this only from the curated bundle resources.
    struct Payload {
        let dll: URL
        let source: URL
        let license: URL
        let dllSHA256: String
        let sourceSHA256: String
        let licenseSHA256: String
    }

    /// Unknown runtime builds are deliberately left untouched. Only the exact
    /// stock Wine 11 CPU ABI is eligible, never a version string alone.
    static func prepare(runtime: RuntimeDescriptor, prefix: URL, bottleDirectory: URL) throws -> Bool {
        #if arch(arm64)
        guard runtime.version == "wine-11.0", runtime.executableURL.isFileURL else { return false }
        let bin = runtime.executableURL.deletingLastPathComponent().standardizedFileURL
        let root = bin.deletingLastPathComponent()
        let runtimeCPU = root.appendingPathComponent("lib/wine/x86_64-windows/wow64cpu.dll")
        do {
            for directory in [root, bin, root.appendingPathComponent("lib"),
                              root.appendingPathComponent("lib/wine"),
                              runtimeCPU.deletingLastPathComponent()] {
                try requireDirectory(directory)
            }
            guard try hash(runtimeCPU, maximum: dllMaximum) == originalSHA256 else { return false }
        } catch {
            // Missing, linked, unreadable or otherwise untrusted runtime CPUs
            // cannot establish the known ABI. Never modify such a runtime.
            return false
        }
        guard let dll = Bundle.module.url(forResource: componentID, withExtension: "dll"),
              let source = Bundle.module.url(forResource: componentID + "-source", withExtension: "tar.gz"),
              let license = Bundle.module.url(forResource: "LICENSE-WINE-WOW64CPU", withExtension: "txt") else {
            throw MagicWineError.setup("The bundled Rosetta CPU compatibility files are missing. Reinstall this MagicWine build; no DLL was replaced.")
        }
        let payload = Payload(dll: dll, source: source, license: license,
                              dllSHA256: bundledDLLSHA256, sourceSHA256: bundledSourceSHA256,
                              licenseSHA256: bundledLicenseSHA256)
        return try install(prefix: prefix, bottleDirectory: bottleDirectory,
                           payload: payload, originalSHA256: originalSHA256)
        #else
        return false
        #endif
    }

    /// There is no receipt-supplied trust: both a reused installation and its
    /// preserved original must match the independently supplied curated digests.
    @discardableResult
    static func install(prefix: URL, bottleDirectory: URL, payload: Payload,
                        originalSHA256: String) throws -> Bool {
        let bottle = bottleDirectory.standardizedFileURL
        let prefix = prefix.standardizedFileURL
        guard bottleDirectory.isFileURL, prefix.isFileURL,
              prefix == bottle.appendingPathComponent("prefix", isDirectory: true) else {
            throw MagicWineError.setup("Rosetta CPU compatibility requires the bottle's owned prefix.")
        }
        try validatePrefix(prefix, bottle: bottle)
        let destination = prefix.appendingPathComponent("drive_c/windows/system32/wow64cpu.dll")
        let current = try hash(destination, maximum: dllMaximum)
        guard current == originalSHA256 || current == payload.dllSHA256 else {
            throw MagicWineError.setup("The bottle has a custom wow64cpu.dll. Rosetta CPU compatibility will not overwrite it.")
        }

        // Validate every bundled artifact before creating any installation files.
        for url in [payload.dll, payload.source, payload.license] {
            guard url.isFileURL else { throw MagicWineError.setup("Rosetta CPU resources must be local files.") }
            try requireDirectory(url.deletingLastPathComponent())
        }
        try verify(payload.dll, digest: payload.dllSHA256, maximum: dllMaximum)
        try verify(payload.source, digest: payload.sourceSHA256, maximum: sourceMaximum)
        try verify(payload.license, digest: payload.licenseSHA256, maximum: licenseMaximum)

        let compatibility = bottle.appendingPathComponent("runtime-compatibility", isDirectory: true)
        let backup = compatibility.appendingPathComponent(componentID, isDirectory: true)
        if try exists(compatibility) { try requireDirectory(compatibility) }
        if try exists(backup) {
            try validateBackup(backup, payload: payload, originalSHA256: originalSHA256)
        } else {
            guard current == originalSHA256 else {
                throw MagicWineError.setup("The managed wow64cpu.dll has no verified original backup. The bottle was left unchanged.")
            }
            if try !exists(compatibility) {
                try manager.createDirectory(at: compatibility, withIntermediateDirectories: false)
            }
            try requireDirectory(compatibility)
            let stage = compatibility.appendingPathComponent(".prepare-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: stage) }
            try manager.copyItem(at: destination, to: stage.appendingPathComponent(originalName))
            try manager.copyItem(at: payload.source, to: stage.appendingPathComponent(sourceName))
            try manager.copyItem(at: payload.license, to: stage.appendingPathComponent(licenseName))
            try validateBackup(stage, payload: payload, originalSHA256: originalSHA256)
            try validatePrefix(prefix, bottle: bottle)
            try requireDirectory(compatibility)
            // Publish the complete original/source/license set without ever
            // replacing an existing directory or its possibly custom contents.
            guard renamex_np(stage.path, backup.path, UInt32(RENAME_EXCL)) == 0 else {
                throw pathError("publish the original CPU backup", backup)
            }
        }

        // A previous launch or interrupted preparation can already have the full
        // backup. A native DLL without that backup is never adopted or repaired.
        if current == payload.dllSHA256 {
            try validatePrefix(prefix, bottle: bottle)
            try verify(destination, digest: payload.dllSHA256, maximum: dllMaximum)
            return true
        }
        let system32 = destination.deletingLastPathComponent()
        let stage = system32.appendingPathComponent(".wow64cpu-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        let stagedDLL = stage.appendingPathComponent("wow64cpu.dll")
        try manager.copyItem(at: payload.dll, to: stagedDLL)
        try verify(stagedDLL, digest: payload.dllSHA256, maximum: dllMaximum)
        try validatePrefix(prefix, bottle: bottle)
        try requireDirectory(compatibility)
        try validateBackup(backup, payload: payload, originalSHA256: originalSHA256)
        try verify(destination, digest: originalSHA256, maximum: dllMaximum)
        // Same-filesystem rename is the last mutation. An already mapped DLL
        // keeps its original inode; no loaded image is truncated or written in place.
        guard rename(stagedDLL.path, destination.path) == 0 else {
            throw pathError("atomically replace the bottle CPU", destination)
        }
        return true
    }

    private static func validatePrefix(_ prefix: URL, bottle: URL) throws {
        let bottles = bottle.deletingLastPathComponent()
        for directory in [bottles.deletingLastPathComponent(), bottles, bottle, prefix] {
            try requireDirectory(directory)
        }
        for path in ["drive_c", "drive_c/windows", "drive_c/windows/system32"] {
            try requireDirectory(prefix.appendingPathComponent(path, isDirectory: true))
        }
    }

    private static func validateBackup(_ backup: URL, payload: Payload,
                                       originalSHA256: String) throws {
        try requireDirectory(backup)
        guard Set(try manager.contentsOfDirectory(atPath: backup.path)) == Set([originalName, sourceName, licenseName]) else {
            throw MagicWineError.setup("The Rosetta CPU backup is incomplete or contains unrecognized files. It was left unchanged.")
        }
        try verify(backup.appendingPathComponent(originalName), digest: originalSHA256, maximum: dllMaximum)
        try verify(backup.appendingPathComponent(sourceName), digest: payload.sourceSHA256, maximum: sourceMaximum)
        try verify(backup.appendingPathComponent(licenseName), digest: payload.licenseSHA256, maximum: licenseMaximum)
    }

    private static func verify(_ url: URL, digest: String, maximum: Int) throws {
        guard try hash(url, maximum: maximum) == digest else {
            throw MagicWineError.setup("Rosetta CPU compatibility SHA-256 mismatch: \(url.path). No DLL was replaced.")
        }
    }

    private static func exists(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 { return true }
        if errno == ENOENT { return false }
        throw pathError("inspect", url)
    }

    private static func requireDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw pathError("inspect", url) }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw MagicWineError.setup("Rosetta CPU compatibility requires an ordinary directory, not a symbolic link: \(url.path).")
        }
    }

    private static func hash(_ url: URL, maximum: Int) throws -> String {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw pathError("read without following links", url) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), before.st_nlink == 1,
              before.st_size > 0, before.st_size <= maximum else {
            throw MagicWineError.setup("Rosetta CPU compatibility requires a nonempty ordinary file without hard links and within its size limit: \(url.path).")
        }
        var digest = SHA256()
        var count = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            count += chunk.count
            guard count <= maximum else { throw MagicWineError.setup("Rosetta CPU file exceeds its size limit: \(url.path).") }
            digest.update(data: chunk)
        }
        var after = stat()
        guard lstat(url.path, &after) == 0, after.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              after.st_nlink == 1, after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size, count == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw MagicWineError.setup("A Rosetta CPU file changed during validation: \(url.path).")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func pathError(_ operation: String, _ url: URL) -> MagicWineError {
        let code = errno
        return .setup("Cannot \(operation) Rosetta CPU path \(url.path): \(String(cString: strerror(code))).")
    }
}
