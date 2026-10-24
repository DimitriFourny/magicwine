import Foundation
import Testing
@testable import MagicWineCore

struct DependencyTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("dependency-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func peImage(machine: UInt16, marker: String? = nil, filler: UInt8 = 0) -> Data {
        var bytes = Data(repeating: filler, count: 256)
        bytes.replaceSubrange(64..<128, with: Data(repeating: 0, count: 64))
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 128; bytes[61] = 0; bytes[62] = 0; bytes[63] = 0
        if let marker { bytes.replaceSubrange(64..<(64 + marker.utf8.count), with: Data(marker.utf8)) }
        bytes.replaceSubrange(128..<154, with: Data(repeating: 0, count: 26))
        bytes[128] = 0x50; bytes[129] = 0x45
        bytes[132] = UInt8(truncatingIfNeeded: machine); bytes[133] = UInt8(machine >> 8)
        bytes[148] = 0x60; bytes[151] = 0x20
        return bytes
    }

    private func prefix(in root: URL) throws -> URL {
        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        for folder in ["system32", "syswow64", "temp"] {
            try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/" + folder),
                                                    withIntermediateDirectories: true)
        }
        return prefix
    }

    private func item(downloads: [DependencyDownload], files: [DependencyFile] = []) -> DependencyItem {
        DependencyItem(id: "test-item", name: "Test", version: "1", summary: "", architectures: [.x64],
                       license: DependencyLicense(name: "Test", url: URL(string: "https://example.com/license")!),
                       downloads: downloads, method: files.isEmpty ? .silentInstaller(arguments: ["/quiet"]) : .files(files),
                       registry: [], checks: [])
    }

    // MARK: Catalog

    @Test func catalogPinsEveryDownloadAndFile() {
        let items = DependencyCatalog.items
        #expect(Set(items.map(\.id)).count == items.count)
        #expect(["vcrun2022-x64", "vcrun2022-x86", "d3dcompiler_47", "corefonts"].allSatisfy { DependencyCatalog.item(id: $0) != nil })
        let hex = Set("0123456789abcdef")
        for item in items {
            #expect(!item.downloads.isEmpty && !item.checks.isEmpty, "\(item.id)")
            #expect(item.license.url.scheme == "https", "\(item.id)")
            #expect(Set(item.downloads.map(\.fileName)).count == item.downloads.count, "\(item.id)")
            for download in item.downloads {
                #expect(download.url.scheme == "https", "\(download.url)")
                #expect(!download.url.path.contains("/latest"), "\(download.url)")
                #expect(download.sha256.count == 64 && download.sha256.allSatisfy(hex.contains), "\(download.url)")
                #expect(download.size > 0 && !download.fileName.isEmpty && !download.fileName.contains("/"))
            }
            if case .files(let files) = item.method {
                #expect(Set(files.map(\.destination)).count == files.count, "\(item.id)")
                for file in files {
                    #expect(item.downloads.indices.contains(file.download), "\(file.member)")
                    #expect(file.sha256.count == 64 && file.sha256.allSatisfy(hex.contains), "\(file.member)")
                    #expect(file.destination.split(separator: "/").count == 2, "\(file.destination)")
                    if let machine = file.machine {
                        // A 64-bit (WoW64) prefix keeps 64-bit DLLs in system32 and 32-bit DLLs in syswow64.
                        #expect(file.destination.hasPrefix(machine == PEInspector.amd64 ? "system32/" : "syswow64/"))
                    } else {
                        #expect(file.destination.hasPrefix("Fonts/") && file.fontName != nil)
                    }
                }
            } else {
                #expect(item.downloads.count == 1, "\(item.id)")
            }
        }
    }

    // MARK: Planning

    @Test func installerItemsRunSilentlyThenWriteTheirOverrides() throws {
        let vc = try #require(DependencyCatalog.item(id: "vcrun2022-x86"))
        let steps = DependencyInstaller.steps(for: vc)
        #expect(steps.count == 2)
        #expect(steps.first == .runInstaller(download: 0, arguments: ["/install", "/quiet", "/norestart"]))
        guard case .importRegistry(let text) = steps.last else { Issue.record("missing registry step"); return }
        #expect(text.hasPrefix("REGEDIT4\r\n"))
        #expect(text.contains("[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\r\n\"concrt140\"=\"native,builtin\""))
        #expect(text.contains("\"msvcp140\"=\"native,builtin\"\r\n"))
        // vcruntime140_1 ships only in the x64 redistributable.
        #expect(!text.contains("vcruntime140_1"))
        let x64 = DependencyInstaller.steps(for: try #require(DependencyCatalog.item(id: "vcrun2022-x64")))
        guard case .importRegistry(let x64Text) = x64.last else { Issue.record("missing registry step"); return }
        #expect(x64Text.contains("\"vcruntime140_1\"=\"native,builtin\""))
    }

    @Test func fileItemsExtractPerDownloadPlaceAndRegister() throws {
        let compiler = try #require(DependencyCatalog.item(id: "d3dcompiler_47"))
        let steps = DependencyInstaller.steps(for: compiler)
        guard case .files(let files) = compiler.method else { Issue.record("not a file item"); return }
        #expect(steps == [.extract(download: 0, members: ["fila319f706acfa16d6707473ebf29bdc7f"]),
                          .extract(download: 1, members: ["fil3585cb2ea5db13cc0838f8d06b5c9679"]),
                          .place(files),
                          .importRegistry("REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]\r\n\"d3dcompiler_47\"=\"native\"\r\n")])

        let fonts = try #require(DependencyCatalog.item(id: "corefonts"))
        let fontSteps = DependencyInstaller.steps(for: fonts)
        #expect(fontSteps.filter { if case .extract = $0 { true } else { false } }.count == fonts.downloads.count)
        guard case .importRegistry(let text) = fontSteps.last else { Issue.record("missing registry step"); return }
        for key in ["Windows NT\\CurrentVersion\\Fonts", "Windows\\CurrentVersion\\Fonts"] {
            #expect(text.contains("[HKEY_LOCAL_MACHINE\\Software\\Microsoft\\\(key)]\r\n\"Andale Mono (TrueType)\"=\"andalemo.ttf\""))
        }
        #expect(text.contains("\"Arial Bold Italic (TrueType)\"=\"arialbi.ttf\""))
    }

    @Test func registryFilesEscapeNamesAndValues() {
        let text = DependencyInstaller.registryFile([
            DependencyRegistryValue(hive: .localMachine, key: #"Software\Test"#, name: #"Quote " Name"#, value: #"C:\path"#)
        ])
        #expect(text == "REGEDIT4\r\n\r\n[HKEY_LOCAL_MACHINE\\Software\\Test]\r\n\"Quote \\\" Name\"=\"C:\\\\path\"\r\n")
    }

    // MARK: Download cache

    @Test func checksumMismatchIsRefusedAndNothingIsCached() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let served = root.appendingPathComponent("served.exe")
        try Data("tampered".utf8).write(to: served)
        let download = DependencyDownload(url: URL(string: "https://example.com/setup.exe")!, fileName: "setup.exe",
                                          sha256: SecureFS.digest(Data("expected".utf8)), size: 8)
        let fetch: DependencyInstaller.Fetch = { _, _ in
            let copy = root.appendingPathComponent("fetched-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: served, to: copy)
            return copy
        }
        await #expect(throws: MagicWineError.self) {
            _ = try await DependencyInstaller.cachedDownload(download, of: item(downloads: [download]), paths: paths, fetch: fetch)
        }
        let cache = DependencyInstaller.cacheDirectory(paths: paths)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path).isEmpty)
    }

    @Test func cachedDownloadsAreVerifiedOnEveryUseAndDamagedOnesReplaced() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let content = Data("pinned installer".utf8)
        let download = DependencyDownload(url: URL(string: "https://example.com/setup.exe")!, fileName: "setup.exe",
                                          sha256: SecureFS.digest(content), size: Int64(content.count))
        let fetches = Counter()
        let fetch: DependencyInstaller.Fetch = { _, _ in
            fetches.increment()
            let copy = root.appendingPathComponent("fetched-\(UUID().uuidString)")
            try content.write(to: copy)
            return copy
        }
        let target = item(downloads: [download])
        let first = try await DependencyInstaller.cachedDownload(download, of: target, paths: paths, fetch: fetch)
        #expect(first.path.hasSuffix("Components/dependencies/test-item-\(download.sha256.prefix(12))/setup.exe"))
        #expect(try Data(contentsOf: first) == content)
        _ = try await DependencyInstaller.cachedDownload(download, of: target, paths: paths, fetch: fetch)
        #expect(fetches.value == 1)

        try Data("pinned installeR".utf8).write(to: first)
        let repaired = try await DependencyInstaller.cachedDownload(download, of: target, paths: paths, fetch: fetch)
        #expect(fetches.value == 2)
        #expect(try Data(contentsOf: repaired) == content)

        // A link in place of the cached entry is never followed or removed.
        let directory = first.deletingLastPathComponent()
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root)
        await #expect(throws: MagicWineError.self) {
            _ = try await DependencyInstaller.cachedDownload(download, of: target, paths: paths, fetch: fetch)
        }
        #expect(fetches.value == 2)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    // MARK: Placement and checks

    @Test func placementReplacesWineBuiltinsButNeverUnknownFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try prefix(in: root)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        let dll64 = peImage(machine: PEInspector.amd64, filler: 1)
        let dll32 = peImage(machine: PEInspector.i386, filler: 2)
        let font = Data("font".utf8)
        let files = [
            DependencyFile(download: 0, member: "a", sha256: SecureFS.digest(dll64), size: dll64.count,
                           destination: "system32/test.dll", machine: PEInspector.amd64, fontName: nil),
            DependencyFile(download: 0, member: "b", sha256: SecureFS.digest(dll32), size: dll32.count,
                           destination: "syswow64/test.dll", machine: PEInspector.i386, fontName: nil),
            DependencyFile(download: 0, member: "c", sha256: SecureFS.digest(font), size: font.count,
                           destination: "Fonts/test.ttf", machine: nil, fontName: "Test")
        ]
        var sources: [DependencyFile: URL] = [:]
        for (file, data) in zip(files, [dll64, dll32, font]) {
            let url = root.appendingPathComponent(file.member)
            try data.write(to: url)
            sources[file] = url
        }
        let builtin = peImage(machine: PEInspector.amd64, marker: "Wine builtin DLL\0")
        try builtin.write(to: windows.appendingPathComponent("system32/test.dll"))
        let custom = peImage(machine: PEInspector.i386, filler: 9)
        try custom.write(to: windows.appendingPathComponent("syswow64/test.dll"))

        #expect(throws: MagicWineError.self) { try DependencyInstaller.place(sources, prefix: prefix) }
        // The refusal happens before anything is replaced or created.
        #expect(try Data(contentsOf: windows.appendingPathComponent("system32/test.dll")) == builtin)
        #expect(try Data(contentsOf: windows.appendingPathComponent("syswow64/test.dll")) == custom)
        #expect(!FileManager.default.fileExists(atPath: windows.appendingPathComponent("Fonts/test.ttf").path))

        try FileManager.default.removeItem(at: windows.appendingPathComponent("syswow64/test.dll"))
        try DependencyInstaller.place(sources, prefix: prefix)
        #expect(try Data(contentsOf: windows.appendingPathComponent("system32/test.dll")) == dll64)
        #expect(try Data(contentsOf: windows.appendingPathComponent("syswow64/test.dll")) == dll32)
        #expect(try Data(contentsOf: windows.appendingPathComponent("Fonts/test.ttf")) == font)
        // Already installed pinned files are accepted as they are.
        try DependencyInstaller.place(sources, prefix: prefix)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: windows.appendingPathComponent("system32").path)
        #expect(leftovers == ["test.dll"])

        #expect(try DependencyInstaller.isNativeDLL(windows.appendingPathComponent("system32/test.dll"), machine: PEInspector.amd64))
        try builtin.write(to: windows.appendingPathComponent("system32/test.dll"))
        #expect(try !DependencyInstaller.isNativeDLL(windows.appendingPathComponent("system32/test.dll"), machine: PEInspector.amd64))
    }

    @Test func statusReadsWineRegistryFilesAndReportsMissingChecks() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = try prefix(in: root)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        let compiler = try #require(DependencyCatalog.item(id: "d3dcompiler_47"))
        let empty = DependencyInstaller.status(of: compiler, prefix: prefix, record: nil)
        #expect(!empty.isInstalled && !empty.isPartial)

        try peImage(machine: PEInspector.amd64).write(to: windows.appendingPathComponent("system32/d3dcompiler_47.dll"))
        try peImage(machine: PEInspector.i386).write(to: windows.appendingPathComponent("syswow64/d3dcompiler_47.dll"))
        let partial = DependencyInstaller.status(of: compiler, prefix: prefix, record: nil)
        #expect(partial.isPartial)
        #expect(partial.missing == [#"HKEY_CURRENT_USER\Software\Wine\DllOverrides\d3dcompiler_47"#])

        try """
        WINE REGISTRY Version 2
        ;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000

        #arch=win64

        [Software\\\\Wine\\\\DllOverrides] 1792842610
        #time=1dd63add2de5de2
        "*d3dcompiler_47"="native"
        "D3DCompiler_47"="native"

        """.write(to: prefix.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)
        #expect(DependencyInstaller.status(of: compiler, prefix: prefix, record: nil).isInstalled)

        // A Wine builtin in place of the native DLL is not installed.
        try peImage(machine: PEInspector.i386, marker: "Wine builtin DLL\0")
            .write(to: windows.appendingPathComponent("syswow64/d3dcompiler_47.dll"))
        #expect(DependencyInstaller.status(of: compiler, prefix: prefix, record: nil).missing == ["native syswow64/d3dcompiler_47.dll"])
    }

    // MARK: Runtime and metadata

    @Test func installationRequiresLicenseConsentAndKnownItemsBeforeAnyDownload() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let store = BottleStore(paths: paths)
        let bottle = try await store.create(name: "Deps", runtime: RuntimeDescriptor(
            executableURL: root.appendingPathComponent("bin/wine"), version: "wine-11.0"))
        let wine = WineRuntime(paths: paths, store: store)
        await #expect(throws: MagicWineError.self) {
            _ = try await wine.installDependencies(["corefonts"], in: bottle, acceptLicense: false)
        }
        await #expect(throws: MagicWineError.self) {
            _ = try await wine.installDependencies(["corefonts", "dotnet48"], in: bottle, acceptLicense: true)
        }
        #expect(!FileManager.default.fileExists(atPath: DependencyInstaller.cacheDirectory(paths: paths).path))
        #expect(ProcessLogs.list(bottle: bottle.id, paths: paths).isEmpty)
    }

    @Test func bottleMetadataDecodesWithoutDependenciesAndRoundTrips() throws {
        let record = InstalledDependency(id: "corefonts", version: "2000", installedAt: Date(timeIntervalSinceReferenceDate: 814_535_415))
        let bottle = Bottle(name: "Old", runtime: RuntimeDescriptor(executableURL: URL(fileURLWithPath: "/tmp/wine"), version: "wine-11.0"),
                            dependencies: [record])
        let data = try JSONEncoder().encode(bottle)
        #expect(try JSONDecoder().decode(Bottle.self, from: data).dependencies == [record])
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "dependencies")
        let old = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Bottle.self, from: old).dependencies.isEmpty)
    }

    @Test func generalSaveCannotRewriteRecordedDependencies() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BottleStore(paths: ApplicationPaths(root: root))
        let bottle = try await store.create(name: "Deps", runtime: RuntimeDescriptor(
            executableURL: root.appendingPathComponent("bin/wine"), version: "wine-11.0"))
        let record = InstalledDependency(id: "corefonts", version: "2000", installedAt: Date(timeIntervalSinceReferenceDate: 814_535_415))
        let recorded = try await store.recordDependency(record, in: bottle)
        #expect(recorded.dependencies == [record])
        // A stale copy without the record must not erase it.
        await #expect(throws: MagicWineError.self) { try await store.save(bottle) }
        var renamed = recorded
        renamed.name = "Renamed"
        try await store.save(renamed)
        #expect(try await store.list().first?.dependencies == [record])
    }
}
