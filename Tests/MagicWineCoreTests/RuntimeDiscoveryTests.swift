import Foundation
import Testing
@testable import MagicWineCore

/// Discovery reuses `wine --version` results of unchanged executables across app starts.
struct RuntimeDiscoveryTests {
    private struct Fixture {
        let paths: ApplicationPaths
        let wine: WineRuntime

        init() throws {
            paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            wine = Self.runtime(paths)
        }

        /// A separate runtime of the same library, as after restarting the app.
        static func runtime(_ paths: ApplicationPaths) -> WineRuntime {
            WineRuntime(paths: paths, store: BottleStore(paths: paths))
        }

        var cache: URL { paths.root.appendingPathComponent(RuntimeInspectionCache.fileName) }

        func executable(_ name: String) -> URL {
            paths.root.appendingPathComponent("wines/\(name)/bin/wine")
        }

        /// A fake Wine that counts how often it runs.
        @discardableResult
        func fakeWine(_ name: String, version: String? = "wine-9.0 (Fake)", body: String = "") throws -> URL {
            let url = executable(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let report = version.map { "printf '%s\\n' '\($0)'" } ?? "true"
            let script = "#!/bin/sh\necho run >> '\(runs(name).path)'\n\(body)\n\(report)\n"
            try Data(script.utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        func runs(_ name: String) -> URL { paths.root.appendingPathComponent("runs-\(name)") }

        func runCount(_ name: String) -> Int {
            ((try? String(contentsOf: runs(name), encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    @Test func unchangedExecutablesAreNotRunAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wine = try fixture.fakeWine("stable")
        let expected = [RuntimeDescriptor(executableURL: wine, version: "wine-9.0 (Fake)")]
        #expect(await fixture.wine.discover(candidates: [wine]) == expected)
        #expect(fixture.runCount("stable") == 1)
        #expect(await fixture.wine.discover(candidates: [wine]) == expected)
        // A new app start (another runtime of the library) reads the persisted result.
        #expect(await Fixture.runtime(fixture.paths).discover(candidates: [wine]) == expected)
        #expect(fixture.runCount("stable") == 1)
        // An explicit custom Wine reuses it too; a plain inspection always runs.
        #expect(try await fixture.wine.inspect(executableURL: wine, reusingCachedResult: true) == expected[0])
        #expect(fixture.runCount("stable") == 1)
        #expect(try await fixture.wine.inspect(executableURL: wine) == expected[0])
        #expect(fixture.runCount("stable") == 2)
    }

    @Test func changedExecutablesAreInspectedAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wine = try fixture.fakeWine("custom")
        _ = await fixture.wine.discover(candidates: [wine])
        #expect(fixture.runCount("custom") == 1)

        // New contents (size and modification time change).
        try fixture.fakeWine("custom", version: "wine-10.0 (Updated)")
        #expect(try await fixture.wine.inspect(executableURL: wine, reusingCachedResult: true).version == "wine-10.0 (Updated)")
        #expect(fixture.runCount("custom") == 2)
        #expect(await fixture.wine.discover(candidates: [wine]).map(\.version) == ["wine-10.0 (Updated)"])
        #expect(fixture.runCount("custom") == 2)

        // The same bytes and modification time in a new file (another inode).
        let before = try #require(RuntimeInspectionCache.stamp(of: wine))
        let replacement = wine.deletingLastPathComponent().appendingPathComponent("replacement")
        try FileManager.default.copyItem(at: wine, to: replacement)
        var status = stat()
        #expect(lstat(wine.path, &status) == 0)
        let times = [status.st_atimespec, status.st_mtimespec]
        #expect(utimensat(AT_FDCWD, replacement.path, times, AT_SYMLINK_NOFOLLOW) == 0)
        #expect(rename(replacement.path, wine.path) == 0)
        let after = try #require(RuntimeInspectionCache.stamp(of: wine))
        #expect(after.size == before.size && after.modifiedSeconds == before.modifiedSeconds &&
                after.modifiedNanoseconds == before.modifiedNanoseconds && after.inode != before.inode)
        #expect(await fixture.wine.discover(candidates: [wine]).map(\.version) == ["wine-10.0 (Updated)"])
        #expect(fixture.runCount("custom") == 3)
    }

    @Test func corruptOrForeignCachesAreIgnoredAndReplaced() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let wine = try fixture.fakeWine("stable")
        for contents in ["not json", #"{"schema": 99, "runtimes": []}"#, #"{"schema": 1, "runtimes": [{"path": 1}]}"#] {
            try Data(contents.utf8).write(to: fixture.cache)
            let before = fixture.runCount("stable")
            #expect(await fixture.wine.discover(candidates: [wine]).map(\.version) == ["wine-9.0 (Fake)"])
            #expect(fixture.runCount("stable") == before + 1)
            // The rewritten cache is valid again.
            _ = await fixture.wine.discover(candidates: [wine])
            #expect(fixture.runCount("stable") == before + 1)
        }
        // A cache that is a link is neither followed nor written through.
        let elsewhere = fixture.paths.root.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: fixture.cache, to: elsewhere)
        let valid = try Data(contentsOf: elsewhere)
        try FileManager.default.createSymbolicLink(at: fixture.cache, withDestinationURL: elsewhere)
        _ = await fixture.wine.discover(candidates: [wine])
        #expect(fixture.runCount("stable") == 4)
        #expect(try Data(contentsOf: elsewhere) == valid)
    }

    @Test func failedInspectionsAreNotCached() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let silent = try fixture.fakeWine("silent", version: nil)
        #expect(await fixture.wine.discover(candidates: [silent]).isEmpty)
        #expect(await fixture.wine.discover(candidates: [silent]).isEmpty)
        #expect(fixture.runCount("silent") == 2)
    }

    @Test func uncachedCandidatesAreInspectedConcurrently() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let started = fixture.paths.root.appendingPathComponent("started", isDirectory: true)
        try FileManager.default.createDirectory(at: started, withIntermediateDirectories: true)
        // Each waits (at most 5 seconds) until another inspection has started too.
        let names = ["a", "b", "c"]
        let wines = try names.map { name in
            try fixture.fakeWine(name, body: """
                touch '\(started.path)/\(name)'
                i=0
                while [ "$(ls '\(started.path)' | wc -l)" -lt 2 ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
                [ "$(ls '\(started.path)' | wc -l)" -ge 2 ] && touch '\(fixture.paths.root.path)/overlapped-\(name)'
                """)
        }
        #expect(await fixture.wine.discover(candidates: wines).count == 3)
        let overlapped = names.filter {
            FileManager.default.fileExists(atPath: fixture.paths.root.appendingPathComponent("overlapped-\($0)").path)
        }
        #expect(overlapped.count >= 2)
    }
}
