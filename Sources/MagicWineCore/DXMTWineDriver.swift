import CryptoKit
import Darwin
import Foundation

/// Installed only in a fresh, private managed Wine staging tree.
/// Never modifies a selected, user-provided, or shared runtime.
enum DXMTWineDriver {
    static let componentID = "winemac-wine11.0-dxmt.1"
    static let originalSHA256 = "7687c4095ea6dba1761052ac19d46db3409a36f2bc827b79c6e32bf779df59f4"
    static let driverSHA256 = "b8d3b7318ea4ab5502ff3b233b997d1e7e3e78535e385870c663e61375548426"
    static let originalName = "original-winemac.so"
    static let sourceName = componentID + "-source.tar.gz"
    static let licenseName = "LICENSE-WINE-DXMT.txt"
    static let provenanceName = componentID + "-provenance.json"
    private static let nativeMaximum = 64 * 1_048_576
    private static let sourceMaximum = 256 * 1_048_576
    private static let textMaximum = 1_048_576
    private static let linkDigests = [
        "ntdll.so": "dfb9d4d4d6e7fd3dc537c1bacd69cb3a6bb46ae98311bb5358df3c4eab470c3f",
        "win32u.so": "5686c667977ab6d4ea932ea53a2a7b73e51c936988118707b85c7619db1dfb98"
    ]
    private static var manager: FileManager { .default }

    struct Artifact {
        let url: URL
        let digest: String
        let maximum: Int
    }

    /// Digests are compiled trust roots, never read from writable runtime receipts.
    static func bundledArtifacts() throws -> [Artifact] {
        let pins: [(String, String, Int)] = [
            (componentID + ".so.deflate", "47dcc92c92286be713d9f164e9e6111af3799b9c66050197baa6ce6d14d7ba9a", nativeMaximum),
            (sourceName, "95229a297a47ff30f3602d272af0d80711a87bdf182b96d84ea2a76591a5b64e", sourceMaximum),
            (licenseName, "66e5a1ad066129a64cd6562c92603b6830553f775aa7abe3a2c11d4a1e44b26e", textMaximum),
            (provenanceName, "8d403b98abe3da5cc07211e8e5298c73f5dd4a0e1a86667731cab588f85d36ef", textMaximum)
        ]
        return try pins.map { name, digest, maximum in
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw failure("Bundled driver artifact is missing: \(name). Reinstall MagicWine.")
            }
            try requireDirectory(url.deletingLastPathComponent())
            try verify(url, digest: digest, maximum: maximum)
            return Artifact(url: url, digest: digest, maximum: maximum)
        }
    }

    /// Keep Mach-O bytes opaque to release-build resource stripping and signing.
    static func unpackDriver(_ artifact: Artifact, to destination: URL) throws {
        let compressed = try Data(contentsOf: artifact.url)
        guard compressed.count <= artifact.maximum,
              SHA256.hash(data: compressed).map({ String(format: "%02x", $0) }).joined() == artifact.digest else {
            throw failure("The compressed driver changed after validation.")
        }
        let payload = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard !payload.isEmpty, payload.count <= nativeMaximum,
              SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined() == driverSHA256 else {
            throw failure("The decompressed driver does not match the pinned native image.")
        }
        try payload.write(to: destination, options: .withoutOverwriting)
    }

    static func install(at executable: URL) throws {
        let root = try validateLayout(executable)
        let native = root.appendingPathComponent("lib/wine/x86_64-unix")
        let driver = native.appendingPathComponent("winemac.so")
        try verify(driver, digest: originalSHA256, maximum: nativeMaximum)
        let artifacts = try bundledArtifacts()
        let compatibility = root.appendingPathComponent("runtime-compatibility", isDirectory: true)
        let backup = compatibility.appendingPathComponent(componentID, isDirectory: true)
        if try exists(compatibility) { try requireDirectory(compatibility) }
        guard try !exists(backup) else {
            throw failure("Driver preparation requires a fresh staging tree; an existing component will not be overwritten.")
        }
        if try !exists(compatibility) {
            try manager.createDirectory(at: compatibility, withIntermediateDirectories: false)
        }
        try requireDirectory(compatibility)
        try manager.createDirectory(at: backup, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        // Preserve the exact stock image and LGPL corresponding source before publication.
        try manager.copyItem(at: driver, to: backup.appendingPathComponent(originalName))
        for artifact in artifacts.dropFirst() {
            try manager.copyItem(at: artifact.url, to: backup.appendingPathComponent(artifact.url.lastPathComponent))
        }
        try validateBackup(backup, artifacts: artifacts)
        let stage = native.appendingPathComponent(".dxmt-driver-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: stage) }
        try unpackDriver(artifacts[0], to: stage)
        try verify(stage, digest: driverSHA256, maximum: nativeMaximum)
        _ = try validateLayout(executable)
        try verify(driver, digest: originalSHA256, maximum: nativeMaximum)
        guard rename(stage.path, driver.path) == 0 else { throw pathError("publish", driver) }
    }

    static func validate(at executable: URL) throws {
        let root = try validateLayout(executable)
        let artifacts = try bundledArtifacts()
        try verify(root.appendingPathComponent("lib/wine/x86_64-unix/winemac.so"),
                   digest: driverSHA256, maximum: nativeMaximum)
        let compatibility = root.appendingPathComponent("runtime-compatibility", isDirectory: true)
        try requireDirectory(compatibility)
        try validateBackup(compatibility.appendingPathComponent(componentID, isDirectory: true), artifacts: artifacts)
    }

    private static func validateLayout(_ executable: URL) throws -> URL {
        guard executable.isFileURL, executable.lastPathComponent == "wine",
              executable.deletingLastPathComponent().lastPathComponent == "bin" else {
            throw failure("Expected the managed runtime's bin/wine executable.")
        }
        let bin = executable.deletingLastPathComponent().standardizedFileURL
        let root = bin.deletingLastPathComponent()
        for directory in [root, bin, root.appendingPathComponent("lib"),
                          root.appendingPathComponent("lib/wine"),
                          root.appendingPathComponent("lib/wine/x86_64-unix")] {
            try requireDirectory(directory)
        }
        // Executable and native link inputs must be ordinary files, not linked aliases.
        _ = try hash(executable, maximum: nativeMaximum)
        for (name, digest) in linkDigests {
            try verify(root.appendingPathComponent("lib/wine/x86_64-unix/" + name),
                       digest: digest, maximum: nativeMaximum)
        }
        return root
    }

    private static func validateBackup(_ backup: URL, artifacts: [Artifact]) throws {
        try requireDirectory(backup)
        let names = Set([originalName] + artifacts.dropFirst().map { $0.url.lastPathComponent })
        guard Set(try manager.contentsOfDirectory(atPath: backup.path)) == names else {
            throw failure("The driver original/source/license/provenance set is incomplete or contains unrecognized files.")
        }
        try verify(backup.appendingPathComponent(originalName), digest: originalSHA256, maximum: nativeMaximum)
        for artifact in artifacts.dropFirst() {
            try verify(backup.appendingPathComponent(artifact.url.lastPathComponent),
                       digest: artifact.digest, maximum: artifact.maximum)
        }
    }

    private static func verify(_ url: URL, digest: String, maximum: Int) throws {
        guard try hash(url, maximum: maximum) == digest else {
            throw failure("SHA-256 mismatch: \(url.path). This runtime must not be reused.")
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
            throw failure("Expected an ordinary directory, not a symbolic link: \(url.path).")
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
            throw failure("Expected a nonempty ordinary file without hard links within its size limit: \(url.path).")
        }
        var digest = SHA256()
        var count = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            count += chunk.count
            guard count <= maximum else { throw failure("File exceeds its size limit: \(url.path).") }
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
            throw failure("File changed during validation: \(url.path).")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func pathError(_ operation: String, _ url: URL) -> MagicWineError {
        let code = errno
        return failure("Cannot \(operation) \(url.path): \(String(cString: strerror(code))).")
    }

    private static func failure(_ message: String) -> MagicWineError {
        .setup("DXMT Wine driver: " + message)
    }
}
