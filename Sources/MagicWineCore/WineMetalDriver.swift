import Darwin
import Foundation

/// Installed only in a fresh, private managed Wine staging tree.
/// Never modifies a selected, user-provided, or shared runtime.
enum WineMetalDriver {
    static let componentID = WineMetalBuildPins.componentID
    static let sourceName = componentID + "-source.tar.gz"
    static let licenseName = WineMetalBuildPins.licenseName
    static let provenanceName = componentID + "-provenance.json"
    /// Staged into the runtime's backup instead of a copy of the bundled `sourceName`.
    static let sourceReferenceName = "CORRESPONDING-SOURCE.txt"
    static let sourceReference = """
    MagicWine Wine Metal driver: \(componentID)
    Corresponding source: \(sourceName), SHA-256 \(WineMetalBuildPins.sourceSHA256)
    License: \(licenseName); build provenance: \(provenanceName) (both in this directory).
    The corresponding source is not copied into this runtime. It ships in MagicWine's
    resource bundle, MagicWine_MagicWineCore.bundle/Contents/Resources/ (inside
    MagicWine.app/Contents/Resources/ or beside the CLI), next to the license.

    """
    private static let nativeMaximum = 64 * 1_048_576
    private static let sourceMaximum = 256 * 1_048_576
    private static let textMaximum = 1_048_576

    typealias Image = WineMetalBuildPins.Image
    static let images = WineMetalBuildPins.images
    private static var manager: FileManager { .default }
    private static let fs = SecureFS(prefix: "Wine Metal driver: ")

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
            (sourceName, WineMetalBuildPins.sourceSHA256, sourceMaximum, nil),
            (licenseName, WineMetalBuildPins.licenseSHA256, textMaximum, nil),
            (provenanceName, WineMetalBuildPins.provenanceSHA256, textMaximum, nil)
        ]
        return try pins.map { name, digest, maximum, image in
            guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
                throw failure("Bundled driver artifact is missing: \(name). Reinstall MagicWine.")
            }
            try fs.requireDirectory(url.deletingLastPathComponent())
            try verify(url, digest: digest, maximum: maximum)
            return Artifact(url: url, digest: digest, maximum: maximum, image: image)
        }
    }

    /// Keep Mach-O and PE bytes opaque to release-build resource processing.
    static func unpackImage(_ artifact: Artifact, to destination: URL) throws {
        guard let image = artifact.image else { throw failure("Expected a compressed driver image.") }
        let compressed = try Data(contentsOf: artifact.url)
        guard compressed.count <= artifact.maximum,
              SecureFS.digest(compressed) == artifact.digest else {
            throw failure("The compressed driver changed after validation.")
        }
        let payload = try (compressed as NSData).decompressed(using: .zlib) as Data
        guard !payload.isEmpty, payload.count <= nativeMaximum,
              SecureFS.digest(payload) == image.digest else {
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
        if try fs.exists(compatibility) { try fs.requireDirectory(compatibility) }
        guard try !fs.exists(backup) else {
            throw failure("Driver preparation requires a fresh staging tree; an existing component will not be overwritten.")
        }
        if try !fs.exists(compatibility) {
            try manager.createDirectory(at: compatibility, withIntermediateDirectories: false)
        }
        try fs.requireDirectory(compatibility)
        try manager.createDirectory(at: backup, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        // Native and PE images form one ABI. The caller publishes the whole runtime
        // only after this private staging tree has been prepared successfully.
        for image in images where image.originalDigest != nil {
            try manager.copyItem(at: root.appendingPathComponent(image.relativePath),
                                 to: backup.appendingPathComponent(image.backupName))
        }
        // The license and provenance are copied; the corresponding source stays in the
        // app's resource bundle and the backup records its name and pin instead.
        for artifact in artifacts where artifact.image == nil && artifact.url.lastPathComponent != sourceName {
            try manager.copyItem(at: artifact.url, to: backup.appendingPathComponent(artifact.url.lastPathComponent))
        }
        try Data(sourceReference.utf8).write(to: backup.appendingPathComponent(sourceReferenceName),
                                             options: .withoutOverwriting)
        try validateBackup(backup, artifacts: artifacts)
        for artifact in artifacts {
            guard let image = artifact.image else { continue }
            let driver = root.appendingPathComponent(image.relativePath)
            let stage = driver.deletingLastPathComponent().appendingPathComponent(".metal-driver-\(UUID().uuidString)")
            defer { try? manager.removeItem(at: stage) }
            try unpackImage(artifact, to: stage)
            _ = try validateLayout(executable)
            try validateOriginal(driver, image: image)
            if image.originalDigest == nil {
                guard try fs.publish(stage, to: driver) else {
                    throw failure("An added driver image requires an absent destination: \(driver.path).")
                }
            } else {
                guard rename(stage.path, driver.path) == 0 else { throw fs.posixFailure("publish", driver) }
            }
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
        try fs.requireDirectory(compatibility)
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
            try fs.requireDirectory(directory)
        }
        // The executable must be an ordinary file, not a linked alias.
        _ = try fs.sha256(executable, maximum: nativeMaximum)
        return root
    }

    /// Accepts exactly one of two pinned inventories: the current one with the source
    /// reference, or the earlier one holding a full copy of the corresponding source
    /// (runtimes staged before it are validated unchanged, never rewritten).
    private static func validateBackup(_ backup: URL, artifacts: [Artifact]) throws {
        try fs.requireDirectory(backup)
        let notices = artifacts.filter { $0.image == nil }
        let originals = images.filter { $0.originalDigest != nil }.map(\.backupName)
        let copiedSource = Set(originals + notices.map { $0.url.lastPathComponent })
        let referencedSource = copiedSource.subtracting([sourceName]).union([sourceReferenceName])
        let names = Set(try manager.contentsOfDirectory(atPath: backup.path))
        guard names == copiedSource || names == referencedSource else {
            throw failure("The driver original/source/license/provenance set is incomplete or contains unrecognized files.")
        }
        for image in images {
            guard let originalDigest = image.originalDigest else { continue }
            try verify(backup.appendingPathComponent(image.backupName),
                       digest: originalDigest, maximum: nativeMaximum)
        }
        for artifact in notices where names.contains(artifact.url.lastPathComponent) {
            try verify(backup.appendingPathComponent(artifact.url.lastPathComponent),
                       digest: artifact.digest, maximum: artifact.maximum)
        }
        if names == referencedSource {
            try verify(backup.appendingPathComponent(sourceReferenceName),
                       digest: SecureFS.digest(Data(sourceReference.utf8)), maximum: textMaximum)
        }
    }

    static func validateOriginal(_ url: URL, image: Image) throws {
        if let digest = image.originalDigest {
            try verify(url, digest: digest, maximum: nativeMaximum)
        } else if try fs.exists(url) {
            throw failure("An added driver image requires an absent destination: \(url.path).")
        }
    }

    private static func verify(_ url: URL, digest: String, maximum: Int) throws {
        guard try fs.sha256(url, maximum: maximum) == digest else {
            throw failure("SHA-256 mismatch: \(url.path). This runtime must not be reused.")
        }
    }

    private static func failure(_ message: String) -> MagicWineError { fs.failure(message) }
}

extension WineMetalBuildPins.Image {
    var backupName: String { "original-" + relativePath.replacingOccurrences(of: "/", with: "-") }
}
