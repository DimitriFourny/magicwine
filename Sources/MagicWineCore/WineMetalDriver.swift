import CryptoKit
import Darwin
import Foundation

/// Installed only in a fresh, private managed Wine staging tree.
/// Never modifies a selected, user-provided, or shared runtime.
enum WineMetalDriver {
    static let componentID = "winemac-wine11.0-metal.1"
    static let sourceName = componentID + "-source.tar.gz"
    static let licenseName = "LICENSE-WINE-METAL.txt"
    static let provenanceName = componentID + "-provenance.json"
    private static let nativeMaximum = 64 * 1_048_576
    private static let sourceMaximum = 256 * 1_048_576
    private static let textMaximum = 1_048_576

    struct Image: Sendable {
        let relativePath: String
        let resourceSuffix: String
        let originalDigest: String
        let digest: String
        let compressedDigest: String
        var backupName: String { "original-" + relativePath.replacingOccurrences(of: "/", with: "-") }
    }
    static let images = [
        Image(relativePath: "x86_64-unix/winemac.so", resourceSuffix: ".so.deflate",
              originalDigest: "7687c4095ea6dba1761052ac19d46db3409a36f2bc827b79c6e32bf779df59f4",
              digest: "7928be846565b328c2e993820ae3ffe24f0fc9a06ac851d9d7ab8de026062dc7",
              compressedDigest: "5510f68d9003253e428a0cb101fa762af649a66d52ec26c53cf6dfe7e8d5394b"),
        Image(relativePath: "x86_64-windows/winemac.drv", resourceSuffix: "-x86_64.drv.deflate",
              originalDigest: "9c52f24507b692ef0fcc0dc5439b8bee63f869f04ef38494bf52e52ddfbfecf0",
              digest: "5519fe75aac10b177003752f93289fd69b4dfaeb6fafba639ec76741265a0e3d",
              compressedDigest: "427e3f3abe154350605092420202002e4afdfd7acde9bef14000387c7a05866d"),
        Image(relativePath: "i386-windows/winemac.drv", resourceSuffix: "-i386.drv.deflate",
              originalDigest: "200a8cd50084d1bd70511681082fbe152a585a8638e84a5aafe8148a8248cda5",
              digest: "832c4e681b845df2cd25e3215143262677c1bfdb51defbcc2578efbc5fe9fd42",
              compressedDigest: "b4254cad181023ea4a6b418cbb2485ae43026d2bf53ab96fd6fc1592421f9faa"),
        Image(relativePath: "x86_64-unix/ntdll.so", resourceSuffix: "-ntdll.so.deflate",
              originalDigest: "dfb9d4d4d6e7fd3dc537c1bacd69cb3a6bb46ae98311bb5358df3c4eab470c3f",
              digest: "ee3db713a091bcc6f34e4b9e9b8587c4c12528a78cf4c970a74780a7b526caee",
              compressedDigest: "92c99a44c743ef31db90ca8886640df4818d9a60dce5e64e6bf7385bf47ec2fd"),
        Image(relativePath: "x86_64-windows/ntdll.dll", resourceSuffix: "-x86_64.ntdll.deflate",
              originalDigest: "d63d10c77a55105d68bf1935ff10137d2ab5e8a4c6ae329aee599f17524b2755",
              digest: "63695dba9ca40e8e75f10470ec5f462a33efe99b717b3551d61a5aeaa1a8effb",
              compressedDigest: "01413b61c1dbcb0c880ae4e1cae73cc96cc996e359af262b12670218c1c6404a"),
        Image(relativePath: "i386-windows/ntdll.dll", resourceSuffix: "-i386.ntdll.deflate",
              originalDigest: "bac6f2d9434860d09a696dcdcd5f85631e19fd4f9409b3a39828841b7a40c089",
              digest: "a5cc94b8824f34cfc41dffeb59cb5873db6523cffa2633dc5d5016650970c579",
              compressedDigest: "c906ffa9bb4f56860a7682202bdf09c25cb342118c37af5695c91dc87d4de460")
    ]
    private static let linkDigests = [
        "win32u.so": "5686c667977ab6d4ea932ea53a2a7b73e51c936988118707b85c7619db1dfb98"
    ]
    private static var manager: FileManager { .default }

    struct Artifact {
        let url: URL
        let digest: String
        let maximum: Int
        let image: Image?
    }

    /// Digests are compiled trust roots, never read from writable runtime receipts.
    static func bundledArtifacts() throws -> [Artifact] {
        var pins: [(String, String, Int, Image?)] = images.map {
            (componentID + $0.resourceSuffix, $0.compressedDigest, nativeMaximum, $0)
        }
        pins += [
            (sourceName, "d372bf69e449591ec3cbd0d6e73a164eed7a42de32c63db0ba88de0db20b7480", sourceMaximum, nil),
            (licenseName, "14fdef09d6e31e46597bbb997dd416b34e4b0bf5c94c9ccbdbfe24b7f9c008cd", textMaximum, nil),
            (provenanceName, "daf6b52fcf3928d9b16e345dabd913ed6e757a39b591fea4b2031d3c22dcd4a6", textMaximum, nil)
        ]
        return try pins.map { name, digest, maximum, image in
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw failure("Bundled driver artifact is missing: \(name). Reinstall MagicWine.")
            }
            try requireDirectory(url.deletingLastPathComponent())
            try verify(url, digest: digest, maximum: maximum)
            return Artifact(url: url, digest: digest, maximum: maximum, image: image)
        }
    }

    /// Keep Mach-O and PE bytes opaque to release-build resource processing.
    static func unpackImage(_ artifact: Artifact, to destination: URL) throws {
        guard let image = artifact.image else { throw failure("Expected a compressed driver image.") }
        let compressed = try Data(contentsOf: artifact.url)
        guard compressed.count <= artifact.maximum,
              SHA256.hash(data: compressed).map({ String(format: "%02x", $0) }).joined() == artifact.digest else {
            throw failure("The compressed driver changed after validation.")
        }
        let payload = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard !payload.isEmpty, payload.count <= nativeMaximum,
              SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined() == image.digest else {
            throw failure("The decompressed driver does not match its pinned image.")
        }
        try payload.write(to: destination, options: .withoutOverwriting)
    }

    static func install(at executable: URL) throws {
        let root = try validateLayout(executable)
        for image in images {
            try verify(root.appendingPathComponent("lib/wine/" + image.relativePath),
                       digest: image.originalDigest, maximum: nativeMaximum)
        }
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
        // Native and PE images form one ABI. The caller publishes the whole runtime
        // only after this private staging tree has been prepared successfully.
        for image in images {
            try manager.copyItem(at: root.appendingPathComponent("lib/wine/" + image.relativePath),
                                 to: backup.appendingPathComponent(image.backupName))
        }
        for artifact in artifacts where artifact.image == nil {
            try manager.copyItem(at: artifact.url, to: backup.appendingPathComponent(artifact.url.lastPathComponent))
        }
        try validateBackup(backup, artifacts: artifacts)
        for artifact in artifacts {
            guard let image = artifact.image else { continue }
            let driver = root.appendingPathComponent("lib/wine/" + image.relativePath)
            let stage = driver.deletingLastPathComponent().appendingPathComponent(".metal-driver-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: stage) }
            try unpackImage(artifact, to: stage)
            _ = try validateLayout(executable)
            try verify(driver, digest: image.originalDigest, maximum: nativeMaximum)
            guard rename(stage.path, driver.path) == 0 else { throw pathError("publish", driver) }
        }
    }

    static func validate(at executable: URL) throws {
        let root = try validateLayout(executable)
        let artifacts = try bundledArtifacts()
        for image in images {
            try verify(root.appendingPathComponent("lib/wine/" + image.relativePath),
                       digest: image.digest, maximum: nativeMaximum)
        }
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
        let directories = [root, bin, root.appendingPathComponent("lib"), root.appendingPathComponent("lib/wine")] +
            images.map { root.appendingPathComponent("lib/wine/" + $0.relativePath).deletingLastPathComponent() }
        for directory in directories {
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
        let notices = artifacts.filter { $0.image == nil }
        let names = Set(images.map(\.backupName) + notices.map { $0.url.lastPathComponent })
        guard Set(try manager.contentsOfDirectory(atPath: backup.path)) == names else {
            throw failure("The driver original/source/license/provenance set is incomplete or contains unrecognized files.")
        }
        for image in images {
            try verify(backup.appendingPathComponent(image.backupName),
                       digest: image.originalDigest, maximum: nativeMaximum)
        }
        for artifact in notices {
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
        .setup("Wine Metal driver: " + message)
    }
}
