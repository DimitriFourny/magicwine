import CryptoKit
import Foundation
import Testing
@testable import MagicWineCore

/// The `*BuildPins.swift` files are compiled trust roots emitted by the component
/// recipes. These tests recompute SHA-256 values of the checked-in resources, so a
/// resource edited without its pins (or pins edited by hand) fails here, not on a
/// user's machine.
struct ComponentPinsTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let resources = repository.appendingPathComponent("Sources/MagicWineCore/Resources", isDirectory: true)

    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(resource name: String) throws -> String {
        try digest(resources.appendingPathComponent(name))
    }

    /// Extracts a bundled `.tar.gz` and returns the SHA-256 of every file below `root`.
    private static func payloadDigests(of archive: String, root: String) throws -> [String: String] {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", resources.appendingPathComponent(archive).path, "-C", destination.path]
        try tar.run()
        tar.waitUntilExit()
        try #require(tar.terminationStatus == 0, "tar failed for \(archive)")
        let base = destination.appendingPathComponent(root, isDirectory: true).resolvingSymlinksInPath().path + "/"
        var result: [String: String] = [:]
        let enumerator = try #require(FileManager.default.enumerator(atPath: base))
        for case let relative as String in enumerator {
            let file = URL(fileURLWithPath: base + relative)
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[relative] = try digest(file)
            }
        }
        return result
    }

    @Test func wineMetalPinsMatchBundledResources() throws {
        let id = WineMetalBuildPins.componentID
        #expect(try Self.digest(resource: id + "-source.tar.gz") == WineMetalBuildPins.sourceSHA256)
        #expect(try Self.digest(resource: WineMetalBuildPins.licenseName) == WineMetalBuildPins.licenseSHA256)
        #expect(try Self.digest(resource: id + "-provenance.json") == WineMetalBuildPins.provenanceSHA256)
        #expect(Set(WineMetalBuildPins.images.map(\.relativePath)).count == WineMetalBuildPins.images.count)
        for image in WineMetalBuildPins.images {
            let name = id + image.resourceSuffix
            #expect(try Self.digest(resource: name) == image.compressedDigest, "\(name)")
            let compressed = try Data(contentsOf: Self.resources.appendingPathComponent(name))
            let payload = try (compressed as NSData).decompressed(using: .zlib) as Data
            #expect(SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined() == image.digest, "\(name) image")
        }
    }

    @Test func dxmtPinsMatchBundledResources() throws {
        let id = DXMTRemoteBuildPins.componentID
        #expect(try Self.digest(resource: id + ".tar.gz") == DXMTRemoteBuildPins.archiveSHA256)
        #expect(try Self.digest(resource: id + "-source.tar.gz") == DXMTRemoteBuildPins.sourceSHA256)
        #expect(try Self.digest(resource: id + "-provenance.json") == DXMTRemoteBuildPins.provenanceSHA256)
        #expect(try Self.digest(resource: DXMTRemoteBuildPins.stockArchiveName) == DXMTRemoteBuildPins.stockArchiveSHA256)
        #expect(try Self.digest(resource: "LICENSE-DXMT.txt") == DXMTRemoteBuildPins.licenseSHA256)
        #expect(try Self.payloadDigests(of: id + ".tar.gz", root: id) == DXMTRemoteBuildPins.payloadDigests)
    }

    @Test func dxvkPinsMatchBundledResources() throws {
        let id = DXVKBuildPins.componentID
        #expect(try Self.digest(resource: id + ".tar.gz") == DXVKBuildPins.archiveSHA256)
        #expect(try Self.digest(resource: DXVKBuildPins.dependencyNoticeName) == DXVKBuildPins.dependencyNoticeSHA256)
        #expect(try Self.payloadDigests(of: id + ".tar.gz", root: id) == DXVKBuildPins.payloadDigests)
    }

    @Test func wow64cpuPinsMatchBundledResources() throws {
        let id = Wow64CPUBuildPins.componentID
        #expect(try Self.digest(resource: id + ".dll") == Wow64CPUBuildPins.dllSHA256)
        #expect(try Self.digest(resource: id + "-source.tar.gz") == Wow64CPUBuildPins.sourceSHA256)
        #expect(try Self.digest(resource: Wow64CPUBuildPins.licenseName) == Wow64CPUBuildPins.licenseSHA256)
    }

    @Test func gamepadBridgeV1PinsMatchBundledResources() throws {
        let id = MagicWineXInputV1BuildPins.componentID
        #expect(try Self.digest(resource: id + "-i686.dll") == MagicWineXInputV1BuildPins.i686SHA256)
        #expect(try Self.digest(resource: id + "-x86_64.dll") == MagicWineXInputV1BuildPins.x8664SHA256)
        #expect(try Self.digest(resource: id + "-source.tar.gz") == MagicWineXInputV1BuildPins.sourceSHA256)
        #expect(try Self.digest(resource: MagicWineXInputV1BuildPins.licenseName) == MagicWineXInputV1BuildPins.licenseSHA256)
    }

    /// A pinned file missing from Package.swift would only fail at runtime ("Reinstall MagicWine").
    @Test func packageManifestBundlesExactlyTheResourceFiles() throws {
        let manifest = try String(contentsOf: Self.repository.appendingPathComponent("Package.swift"), encoding: .utf8)
        let listed = Set(manifest.components(separatedBy: ".copy(\"Resources/").dropFirst().compactMap {
            $0.components(separatedBy: "\"").first
        })
        let present = Set(try FileManager.default.contentsOfDirectory(atPath: Self.resources.path))
        #expect(listed == present)

        let id = WineMetalBuildPins.componentID
        let pinned = Set(WineMetalBuildPins.images.map { id + $0.resourceSuffix } + [
            id + "-source.tar.gz", id + "-provenance.json", WineMetalBuildPins.licenseName,
            DXMTRemoteBuildPins.componentID + ".tar.gz", DXMTRemoteBuildPins.componentID + "-source.tar.gz",
            DXMTRemoteBuildPins.componentID + "-provenance.json", DXMTRemoteBuildPins.stockArchiveName, "LICENSE-DXMT.txt",
            DXVKBuildPins.componentID + ".tar.gz", DXVKBuildPins.dependencyNoticeName,
            Wow64CPUBuildPins.componentID + ".dll", Wow64CPUBuildPins.componentID + "-source.tar.gz",
            Wow64CPUBuildPins.licenseName,
            MagicWineXInputV1BuildPins.componentID + "-i686.dll", MagicWineXInputV1BuildPins.componentID + "-x86_64.dll",
            MagicWineXInputV1BuildPins.componentID + "-source.tar.gz", MagicWineXInputV1BuildPins.licenseName
        ])
        #expect(pinned.isSubset(of: listed))
    }

    /// Component IDs are persisted in bottles, receipts and runtime names; changing one
    /// strands existing installs, so a new component adds an ID instead of renaming.
    @Test func persistedComponentIdentitiesAreStable() {
        #expect(WineMetalDriver.componentID == "winemac-wine11.0-metal.7")
        #expect(DXMTInstallation.componentID == "dxmt-v0.80-remote.1-slim")
        #expect(DXMTInstallation.buildID == "dxmt-v0.80-remote.1")
        // Earlier current DXMT IDs stay retained, so their installs keep launching.
        #expect(Set(DXMTInstallation.retainedComponentIDs) == ["dxmt-v0.80", "dxmt-v0.80-remote.1"])
        #expect(DXVKInstallation.componentID == "dxvk-macos-1.10.3-magicwine.2")
        #expect(DXVKInstallation.version == "1.10.3-magicwine.2")
        #expect(RosettaCPUCompatibility.componentID == "wow64cpu-wine11.0-magicwine.1")
        #expect(GamepadBridge.componentID == "magicwine-xinput-v1")
    }
}
