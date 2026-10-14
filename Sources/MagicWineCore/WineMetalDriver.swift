import CryptoKit
import Darwin
import Foundation

/// Installed only in a fresh, private managed Wine staging tree.
/// Never modifies a selected, user-provided, or shared runtime.
enum WineMetalDriver {
    static let componentID = "winemac-wine11.0-metal.7"
    static let sourceName = componentID + "-source.tar.gz"
    static let licenseName = "LICENSE-WINE-METAL.txt"
    static let provenanceName = componentID + "-provenance.json"
    private static let nativeMaximum = 64 * 1_048_576
    private static let sourceMaximum = 256 * 1_048_576
    private static let textMaximum = 1_048_576

    struct Image: Sendable {
        let relativePath: String
        let resourceSuffix: String
        let originalDigest: String?
        let digest: String
        let compressedDigest: String
        var backupName: String { "original-" + relativePath.replacingOccurrences(of: "/", with: "-") }
    }
    static let images = [
        Image(relativePath: "lib/wine/x86_64-unix/winemac.so", resourceSuffix: ".so.deflate",
              originalDigest: "7687c4095ea6dba1761052ac19d46db3409a36f2bc827b79c6e32bf779df59f4",
              digest: "a2fe10bf083d7199acf1d996a79c89c83be2fcb41bc7c510d0f2d1c99cc812fd",
              compressedDigest: "111c327476cf5c3749af306972788dc41315123a03bda3316fb4e78678bf5e93"),
        Image(relativePath: "lib/wine/x86_64-windows/winemac.drv", resourceSuffix: "-x86_64.drv.deflate",
              originalDigest: "9c52f24507b692ef0fcc0dc5439b8bee63f869f04ef38494bf52e52ddfbfecf0",
              digest: "502443bcc71715b173391e52eb0277b53595e6090fbb3792bb06616b909344b3",
              compressedDigest: "2bc219231b7a5d862e756378a5ce95db17b6ebc031a3d8acdf1bb97cf53e59d2"),
        Image(relativePath: "lib/wine/i386-windows/winemac.drv", resourceSuffix: "-i386.drv.deflate",
              originalDigest: "200a8cd50084d1bd70511681082fbe152a585a8638e84a5aafe8148a8248cda5",
              digest: "9682b258d67d16c63ca7c1fa666280a494fd450fb5ae9730906effb701fa5ca7",
              compressedDigest: "a06d077e695969de74c855d0e36b5ae84756d825c9b1bf6074eb564f49b6f9f2"),
        Image(relativePath: "lib/wine/x86_64-unix/ntdll.so", resourceSuffix: "-ntdll.so.deflate",
              originalDigest: "dfb9d4d4d6e7fd3dc537c1bacd69cb3a6bb46ae98311bb5358df3c4eab470c3f",
              digest: "76b129dda3fea5cc16c5a8dc50c231c7a02566d2c35fd104584f24d394bc7722",
              compressedDigest: "cc620e9398b5147b239413adf47922650b6492629a0a9b410d46f5a37eabcb40"),
        Image(relativePath: "bin/wineserver", resourceSuffix: "-wineserver.deflate",
              originalDigest: "6da7d389c5a35687e580c4988e03f830a73786cf13aba6761e4791ab74aeea2e",
              digest: "dc39a5b3fb6510cf950947d1cf567e7b650383781167f48de4460430ec1025a6",
              compressedDigest: "b97e7b029b67141212e2d6b78b6efcd113c65d4bb9aea7b04513350531da052a"),
        Image(relativePath: "lib/wine/x86_64-windows/ntdll.dll", resourceSuffix: "-x86_64.ntdll.deflate",
              originalDigest: "d63d10c77a55105d68bf1935ff10137d2ab5e8a4c6ae329aee599f17524b2755",
              digest: "63695dba9ca40e8e75f10470ec5f462a33efe99b717b3551d61a5aeaa1a8effb",
              compressedDigest: "01413b61c1dbcb0c880ae4e1cae73cc96cc996e359af262b12670218c1c6404a"),
        Image(relativePath: "lib/wine/i386-windows/ntdll.dll", resourceSuffix: "-i386.ntdll.deflate",
              originalDigest: "bac6f2d9434860d09a696dcdcd5f85631e19fd4f9409b3a39828841b7a40c089",
              digest: "a5cc94b8824f34cfc41dffeb59cb5873db6523cffa2633dc5d5016650970c579",
              compressedDigest: "c906ffa9bb4f56860a7682202bdf09c25cb342118c37af5695c91dc87d4de460"),
        Image(relativePath: "lib/wine/x86_64-unix/win32u.so", resourceSuffix: "-win32u.so.deflate",
              originalDigest: "5686c667977ab6d4ea932ea53a2a7b73e51c936988118707b85c7619db1dfb98",
              digest: "3ed06f88e58a5a3efabb43419cdfe2ffe2109a5f8025512bfad6a86f75644d9f",
              compressedDigest: "e078529ec968140f738d689447e8a05d77e80a5bf7317720e3e0b8d269804533"),
        Image(relativePath: "lib/wine/x86_64-windows/user32.dll", resourceSuffix: "-x86_64.user32.deflate",
              originalDigest: "8ea5e7d18a3d1fc774f56a30c13c1abe0848a3a0af0c2d007e1b852e716a7496",
              digest: "8dee0d4c6ec6fbb3c96f5a925cf63aa6b5d4aa995b90f1056ffb88a1dcb2a556",
              compressedDigest: "9134e73d59c17f599f288fc51936cafd33b0c355de97215a1df739084adecdd4"),
        Image(relativePath: "lib/wine/i386-windows/user32.dll", resourceSuffix: "-i386.user32.deflate",
              originalDigest: "6bc9d98d72f6f2e7a17d0c7f9dc62477f5d39ead0373f788ae60fb137b98e925",
              digest: "725666fc90467e2e965f924a376e4dbbe885cee3180bc9ac84c16dabd8d44528",
              compressedDigest: "ecfe9a9f1e572b34d7087e39bc4fe48251f5461991f1443db2e93ecff24f21e7"),
        Image(relativePath: "lib/wine/x86_64-windows/wow64win.dll", resourceSuffix: "-x86_64.wow64win.deflate",
              originalDigest: "9b87f84fb9320cb100f94b562fa15cbcbc9d84b29a0cf345324fb5f17f12cc39",
              digest: "9608a27a6cc9bdb83814c014fe831e16199ae0264ce10efa97e95f256e592085",
              compressedDigest: "060824be0a7eddb5e727904cb7a4cdf8e5b4b76c0c23132697318e703f20c6d4"),
        Image(relativePath: "lib/wine/x86_64-unix/winhttp.so", resourceSuffix: "-winhttp.so.deflate",
              originalDigest: nil,
              digest: "33579844fa7d4b75bcd3306ed295ca625a966bd9b84a06c9cb787ce9029ac01f",
              compressedDigest: "7d9ae18a200d62d6ad9ceef26e5804ff73b4d7393dcfa0be711d15e023041892"),
        Image(relativePath: "lib/wine/x86_64-windows/winhttp.dll", resourceSuffix: "-x86_64.winhttp.deflate",
              originalDigest: "297679186e7cb8f82e559c02dbd4f40a6b2457e3ac32460f061d142f25f5a857",
              digest: "e9dbcd78079d2da587e8b55c742f26add346974be0fca2c88e3d9f9b3061cd4e",
              compressedDigest: "29543134104414ff04c63e898004600cb4237fc282affc5d858be87de4d42a0c"),
        Image(relativePath: "lib/wine/i386-windows/winhttp.dll", resourceSuffix: "-i386.winhttp.deflate",
              originalDigest: "e1690fcfa7aff4d5add9645bb6b86c1a0a68debdcac75ea2ae55e7a43b7e32da",
              digest: "355918a51cc1669ab6e0b388fdba5f2c4d067cc1089929f2b1eaa409dd79df92",
              compressedDigest: "87581a5733350d694ef615b9b6a41dfc2eeea33233df4564a4f1d044c35aa693")
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
            (sourceName, "b7721fa7e32362905a7afc0810a38dc505f876fc514469ee2f99303b44661601", sourceMaximum, nil),
            (licenseName, "352d42690d61e6bb37d34999c96f1cd5a99d97275b0ccc00a7ba466f788ea96b", textMaximum, nil),
            (provenanceName, "db07b4e2b0df8c0c5296ae55e9bf7b7c1ab0a1e15c0741371d92a8423539d9ec", textMaximum, nil)
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
        if image.relativePath.hasPrefix("bin/") {
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        }
    }

    static func install(at executable: URL) throws {
        let root = try validateLayout(executable)
        for image in images {
            try validateOriginal(root.appendingPathComponent(image.relativePath), image: image)
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
        for image in images where image.originalDigest != nil {
            try manager.copyItem(at: root.appendingPathComponent(image.relativePath),
                                 to: backup.appendingPathComponent(image.backupName))
        }
        for artifact in artifacts where artifact.image == nil {
            try manager.copyItem(at: artifact.url, to: backup.appendingPathComponent(artifact.url.lastPathComponent))
        }
        try validateBackup(backup, artifacts: artifacts)
        for artifact in artifacts {
            guard let image = artifact.image else { continue }
            let driver = root.appendingPathComponent(image.relativePath)
            let stage = driver.deletingLastPathComponent().appendingPathComponent(".metal-driver-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: stage) }
            try unpackImage(artifact, to: stage)
            _ = try validateLayout(executable)
            try validateOriginal(driver, image: image)
            let result = image.originalDigest == nil
                ? renamex_np(stage.path, driver.path, UInt32(RENAME_EXCL))
                : rename(stage.path, driver.path)
            guard result == 0 else { throw pathError("publish", driver) }
        }
    }

    static func validate(at executable: URL) throws {
        let root = try validateLayout(executable)
        let artifacts = try bundledArtifacts()
        for image in images {
            try verify(root.appendingPathComponent(image.relativePath),
                       digest: image.digest, maximum: nativeMaximum)
            if image.relativePath.hasPrefix("bin/"),
               !manager.isExecutableFile(atPath: root.appendingPathComponent(image.relativePath).path) {
                throw failure("The runtime server is not executable.")
            }
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
            images.map { root.appendingPathComponent($0.relativePath).deletingLastPathComponent() }
        for directory in directories {
            try requireDirectory(directory)
        }
        // The executable must be an ordinary file, not a linked alias.
        _ = try hash(executable, maximum: nativeMaximum)
        return root
    }

    private static func validateBackup(_ backup: URL, artifacts: [Artifact]) throws {
        try requireDirectory(backup)
        let notices = artifacts.filter { $0.image == nil }
        let names = Set(images.filter { $0.originalDigest != nil }.map(\.backupName) +
                        notices.map { $0.url.lastPathComponent })
        guard Set(try manager.contentsOfDirectory(atPath: backup.path)) == names else {
            throw failure("The driver original/source/license/provenance set is incomplete or contains unrecognized files.")
        }
        for image in images {
            guard let originalDigest = image.originalDigest else { continue }
            try verify(backup.appendingPathComponent(image.backupName),
                       digest: originalDigest, maximum: nativeMaximum)
        }
        for artifact in notices {
            try verify(backup.appendingPathComponent(artifact.url.lastPathComponent),
                       digest: artifact.digest, maximum: artifact.maximum)
        }
    }

    static func validateOriginal(_ url: URL, image: Image) throws {
        if let digest = image.originalDigest {
            try verify(url, digest: digest, maximum: nativeMaximum)
        } else if try exists(url) {
            throw failure("An added driver image requires an absent destination: \(url.path).")
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
