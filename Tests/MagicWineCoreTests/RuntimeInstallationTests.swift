import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct RuntimeInstallationTests {
    private let quarantineName = "com.apple.quarantine"
    private let quarantineValue = Data("0083;12345678;MagicWineTests;".utf8)
    private let preservedName = "com.magicwine.tests.preserved"
    private let preservedValue = Data([0x00, 0x7f, 0xff, 0x42])

    private struct Fixture {
        let directory: URL
        let paths: ApplicationPaths

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            paths = ApplicationPaths(root: directory.appendingPathComponent("Managed", isDirectory: true))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct Layout {
        let app: URL
        let wine: URL
        let wineserver: URL
        let share: URL
        let entries: [URL]
    }

    private func makeLayout(in runtimeDirectory: URL) throws -> Layout {
        let app = runtimeDirectory.appendingPathComponent("Wine Stable.app", isDirectory: true)
        let directories = [
            app,
            app.appendingPathComponent("Contents", isDirectory: true),
            app.appendingPathComponent("Contents/Resources", isDirectory: true),
            app.appendingPathComponent("Contents/Resources/wine", isDirectory: true),
            app.appendingPathComponent("Contents/Resources/wine/bin", isDirectory: true),
            app.appendingPathComponent("Contents/Resources/wine/share", isDirectory: true),
            app.appendingPathComponent("Contents/Resources/wine/share/.hidden", isDirectory: true),
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let wine = app.appendingPathComponent("Contents/Resources/wine/bin/wine")
        let wineserver = app.appendingPathComponent("Contents/Resources/wine/bin/wineserver")
        let resources = [
            app.appendingPathComponent("Contents/Info.plist"),
            app.appendingPathComponent("Contents/Resources/wine/share/runtime.dat"),
            app.appendingPathComponent("Contents/Resources/wine/share/.hidden/.payload"),
        ]
        for file in [wine, wineserver] + resources {
            try Data([0x01, 0x02]).write(to: file)
        }
        for executable in [wine, wineserver] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        return Layout(app: app, wine: wine, wineserver: wineserver,
                      share: app.appendingPathComponent("Contents/Resources/wine/share", isDirectory: true),
                      entries: directories + [wine, wineserver] + resources)
    }

    private func setAttribute(_ name: String, value: Data, on url: URL) throws {
        let result = url.path.withCString { path in
            name.withCString { attribute in
                value.withUnsafeBytes { bytes in
                    setxattr(path, attribute, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW)
                }
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func attribute(_ name: String, on url: URL) throws -> Data? {
        let size = url.path.withCString { path in
            name.withCString { getxattr(path, $0, nil, 0, 0, XATTR_NOFOLLOW) }
        }
        if size < 0 {
            if errno == ENOATTR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var value = Data(count: size)
        let received = value.withUnsafeMutableBytes { bytes in
            url.path.withCString { path in
                name.withCString { getxattr(path, $0, bytes.baseAddress, bytes.count, 0, XATTR_NOFOLLOW) }
            }
        }
        guard received >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard received == size else { throw POSIXError(.EIO) }
        return value
    }

    private func quarantine(_ urls: [URL]) throws {
        for url in urls {
            try setAttribute(quarantineName, value: quarantineValue, on: url)
        }
    }

    private func expectQuarantineUnchanged(_ urls: [URL]) throws {
        for url in urls {
            #expect(try attribute(quarantineName, on: url) == quarantineValue)
        }
    }

    private func descriptor(at executable: URL) -> RuntimeDescriptor {
        RuntimeDescriptor(executableURL: executable.resolvingSymlinksInPath().standardizedFileURL,
                          version: "wine-11.0")
    }

    @Test(arguments: [false, true])
    func obsoleteManagedPreferenceRequiresCurrentWine(currentInstalled: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runtime = WineRuntime(paths: fixture.paths)
        let current = descriptor(at: RuntimeInstallation.destination(paths: fixture.paths)
            .appendingPathComponent(RuntimeInstallation.relativeExecutable))
        let obsolete = descriptor(at: fixture.paths.runtimesDirectory
            .appendingPathComponent("wine-stable-11.0_1-b50dc50ec7f4")
            .appendingPathComponent(RuntimeInstallation.relativeExecutable))
        let external = descriptor(at: fixture.directory.appendingPathComponent("CustomWine/bin/wine"))
        let available = [external, obsolete] + (currentInstalled ? [current] : [])
        let expected = currentInstalled ? current : nil

        #expect(runtime.preferredRuntime(in: available, preferredPath: obsolete.id) == expected)
        #expect(runtime.preferredRuntime(in: available, preferredPath: nil) == expected)
    }

    @Test(arguments: [false, true])
    func explicitCustomPreferenceDoesNotSilentlySwitchWine(customAvailable: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runtime = WineRuntime(paths: fixture.paths)
        let current = descriptor(at: RuntimeInstallation.destination(paths: fixture.paths)
            .appendingPathComponent(RuntimeInstallation.relativeExecutable))
        // A sibling with the same prefix is not a managed installation.
        let custom = descriptor(at: fixture.paths.root.appendingPathComponent("Runtimes-custom/bin/wine"))
        let available = [current] + (customAvailable ? [custom] : [])

        #expect(runtime.preferredRuntime(in: available, preferredPath: custom.id) == (customAvailable ? custom : nil))
    }

    @Test(arguments: ["wine-test", ".install-test/payload"])
    func removesOnlyManagedBundleQuarantineIncludingHiddenDescendants(runtimePath: String) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let runtimeDirectory = fixture.paths.runtimesDirectory.appendingPathComponent(runtimePath, isDirectory: true)
        let layout = try makeLayout(in: runtimeDirectory)
        try quarantine(layout.entries)
        for entry in layout.entries {
            try setAttribute(preservedName, value: preservedValue, on: entry)
        }

        let sibling = try makeLayout(in: fixture.paths.runtimesDirectory.appendingPathComponent("wine-other"))
        let custom = try makeLayout(in: fixture.directory.appendingPathComponent("CustomWine"))
        let receipt = runtimeDirectory.appendingPathComponent("installation.json")
        let bottleFile = fixture.paths.bottlesDirectory.appendingPathComponent("bottle-file.dat")
        for file in [receipt, bottleFile] {
            try Data([0x42]).write(to: file)
        }
        let untouched = [runtimeDirectory, receipt, bottleFile] + sibling.entries + custom.entries
        try quarantine(untouched)

        let removed = try RuntimeInstallation.removeQuarantine(from: runtimeDirectory, paths: fixture.paths)
        #expect(removed == layout.entries.count)
        for entry in layout.entries {
            #expect(try attribute(quarantineName, on: entry) == nil)
            #expect(try attribute(preservedName, on: entry) == preservedValue)
        }
        try expectQuarantineUnchanged(untouched)

        #expect(try RuntimeInstallation.removeQuarantine(from: runtimeDirectory, paths: fixture.paths) == 0)
        for entry in layout.entries {
            #expect(try attribute(quarantineName, on: entry) == nil)
            #expect(try attribute(preservedName, on: entry) == preservedValue)
        }
        try expectQuarantineUnchanged(untouched)
    }

    @Test(arguments: [false, true])
    func rejectsRuntimeOutsideManagedRootWithoutChangingAttributes(useSymbolicLink: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        // A common path prefix is not containment within the Runtimes directory.
        let externalRuntime = fixture.paths.root.appendingPathComponent("Runtimes-external", isDirectory: true)
        let external = try makeLayout(in: externalRuntime)
        try quarantine(external.entries)
        let candidate: URL
        if useSymbolicLink {
            candidate = fixture.paths.runtimesDirectory.appendingPathComponent("linked-runtime")
            try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: externalRuntime)
        } else {
            candidate = externalRuntime
        }

        #expect(throws: MagicWineError.self) {
            try RuntimeInstallation.removeQuarantine(from: candidate, paths: fixture.paths)
        }
        try expectQuarantineUnchanged(external.entries)
    }

    @Test func rejectsEscapingManagedDirectorySymlinkWithoutChangingExternalAttributes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.paths.root, withIntermediateDirectories: false)
        let externalRuntimes = fixture.directory.appendingPathComponent("ExternalRuntimes", isDirectory: true)
        let externalRuntime = externalRuntimes.appendingPathComponent("wine-test", isDirectory: true)
        let external = try makeLayout(in: externalRuntime)
        try quarantine(external.entries)
        try FileManager.default.createSymbolicLink(at: fixture.paths.runtimesDirectory, withDestinationURL: externalRuntimes)
        let candidate = fixture.paths.runtimesDirectory.appendingPathComponent("wine-test", isDirectory: true)

        #expect(throws: MagicWineError.self) {
            try RuntimeInstallation.removeQuarantine(from: candidate, paths: fixture.paths)
        }
        try expectQuarantineUnchanged(external.entries)
    }

    @Test func rejectsSymbolicLinkAtBundleRootWithoutChangingExternalAttributes() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let runtimeDirectory = fixture.paths.runtimesDirectory.appendingPathComponent("wine-test", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: false)
        let external = try makeLayout(in: fixture.directory.appendingPathComponent("ExternalWine"))
        try quarantine(external.entries)
        try FileManager.default.createSymbolicLink(at: runtimeDirectory.appendingPathComponent("Wine Stable.app"),
                                                  withDestinationURL: external.app)

        #expect(throws: MagicWineError.self) {
            try RuntimeInstallation.removeQuarantine(from: runtimeDirectory, paths: fixture.paths)
        }
        try expectQuarantineUnchanged(external.entries)
    }

    @Test(arguments: [false, true])
    func rejectsNestedEscapingLinkBeforeRemovingAnyQuarantine(linkToDirectory: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let runtimeDirectory = fixture.paths.runtimesDirectory.appendingPathComponent("wine-test", isDirectory: true)
        let layout = try makeLayout(in: runtimeDirectory)
        try quarantine(layout.entries)
        let externalDirectory = fixture.directory.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: externalDirectory, withIntermediateDirectories: false)
        let externalFile = externalDirectory.appendingPathComponent("payload.dat")
        try Data([0x42]).write(to: externalFile)
        try quarantine([externalDirectory, externalFile])
        try FileManager.default.createSymbolicLink(at: layout.share.appendingPathComponent("escape"),
                                                  withDestinationURL: linkToDirectory ? externalDirectory : externalFile)

        #expect(throws: MagicWineError.self) {
            try RuntimeInstallation.removeQuarantine(from: runtimeDirectory, paths: fixture.paths)
        }
        try expectQuarantineUnchanged(layout.entries + [externalDirectory, externalFile])
    }

    @Test func containedSymbolicLinkNeverRemovesSiblingTargetQuarantine() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let runtimeDirectory = fixture.paths.runtimesDirectory.appendingPathComponent("wine-test", isDirectory: true)
        let layout = try makeLayout(in: runtimeDirectory)
        try quarantine(layout.entries)
        let siblingFile = runtimeDirectory.appendingPathComponent("sibling.dat")
        let siblingData = Data([0x21, 0x42])
        try siblingData.write(to: siblingFile)
        try quarantine([siblingFile])
        try setAttribute(preservedName, value: preservedValue, on: siblingFile)
        let link = layout.share.appendingPathComponent("sibling-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: siblingFile)

        #expect(try RuntimeInstallation.removeQuarantine(from: runtimeDirectory, paths: fixture.paths) == layout.entries.count)
        for entry in layout.entries {
            #expect(try attribute(quarantineName, on: entry) == nil)
        }
        try expectQuarantineUnchanged([siblingFile])
        #expect(try attribute(preservedName, on: siblingFile) == preservedValue)
        #expect(try Data(contentsOf: siblingFile) == siblingData)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == siblingFile.path)
    }

    @Test func rejectsNonExecutableLayoutBeforeRemovingAnyQuarantine() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let runtimeDirectory = fixture.paths.runtimesDirectory.appendingPathComponent("wine-test", isDirectory: true)
        let layout = try makeLayout(in: runtimeDirectory)
        try quarantine(layout.entries)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: layout.wineserver.path)

        #expect(throws: MagicWineError.self) {
            try RuntimeInstallation.removeQuarantine(from: runtimeDirectory, paths: fixture.paths)
        }
        try expectQuarantineUnchanged(layout.entries)
    }

    @Test func refusingUnsignedInstallationDoesNotCreateApplicationRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let runtime = WineRuntime(paths: fixture.paths)

        await #expect(throws: MagicWineError.self) {
            try await runtime.installRuntime(acceptUnsigned: false)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.root.path))
    }

    @Test func refusingUnsignedInstallationPreservesExistingRuntimeAndCreatesNoLogs() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let layout = try makeLayout(in: RuntimeInstallation.destination(paths: fixture.paths))
        let entries = layout.entries
        try quarantine(entries)
        for entry in entries {
            try setAttribute(preservedName, value: preservedValue, on: entry)
        }
        let runtime = WineRuntime(paths: fixture.paths)
        let directoriesBefore = try FileManager.default.contentsOfDirectory(atPath: fixture.paths.runtimesDirectory.path)

        await #expect(throws: MagicWineError.self) {
            try await runtime.installRuntime(acceptUnsigned: false)
        }
        try expectQuarantineUnchanged(entries)
        for entry in entries {
            #expect(try attribute(preservedName, on: entry) == preservedValue)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.runtimesDirectory.path) == directoriesBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.logsDirectory.path).isEmpty)
    }


    @Test(arguments: ["source", "sha256", "version", "driverComponentID"], [false, true])
    func rejectsMismatchedCachedReceiptBeforeChangingQuarantine(field: String, missing: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let destination = RuntimeInstallation.destination(paths: fixture.paths)
        let layout = try makeLayout(in: destination)
        try quarantine(layout.entries)
        var receipt = RuntimeInstallation.provenance
        receipt[field] = missing ? nil : "stale-or-corrupt"
        let receiptURL = destination.appendingPathComponent("installation.json")
        let original = try JSONEncoder().encode(receipt)
        try original.write(to: receiptURL)

        #expect(throws: MagicWineError.self) {
            try RuntimeInstallation.reuseCachedRuntime(at: destination, paths: fixture.paths)
        }
        try expectQuarantineUnchanged(layout.entries)
        #expect(try Data(contentsOf: receiptURL) == original)
    }

    @Test func rejectsUnexpectedCachedPathWithoutChangingQuarantine() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let unexpected = fixture.paths.runtimesDirectory.appendingPathComponent("wine-unexpected")
        let layout = try makeLayout(in: unexpected)
        let receiptURL = unexpected.appendingPathComponent("installation.json")
        try JSONEncoder().encode(RuntimeInstallation.provenance).write(to: receiptURL)
        try quarantine(layout.entries + [receiptURL])

        #expect(throws: MagicWineError.self) {
            try RuntimeInstallation.reuseCachedRuntime(at: unexpected, paths: fixture.paths)
        }
        try expectQuarantineUnchanged(layout.entries + [receiptURL])
    }

    @Test func rejectsCorruptDriverWithoutReplacingItOrRemovingQuarantine() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.paths.prepare()
        let destination = RuntimeInstallation.destination(paths: fixture.paths)
        let layout = try makeLayout(in: destination)
        let driver = layout.app.appendingPathComponent("Contents/Resources/wine/lib/wine/x86_64-unix/winemac.so")
        try FileManager.default.createDirectory(at: driver.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("not the pinned DXMT Wine driver".utf8)
        try corrupt.write(to: driver)
        let receipt = RuntimeInstallation.provenance
        let receiptURL = destination.appendingPathComponent("installation.json")
        let receiptData = try JSONEncoder().encode(receipt)
        try receiptData.write(to: receiptURL)
        try quarantine(layout.entries + [driver, receiptURL])

        #expect(throws: MagicWineError.self) {
            try RuntimeInstallation.reuseCachedRuntime(at: destination, paths: fixture.paths)
        }
        #expect(try Data(contentsOf: driver) == corrupt)
        #expect(try Data(contentsOf: receiptURL) == receiptData)
        try expectQuarantineUnchanged(layout.entries + [driver, receiptURL])
    }
}
