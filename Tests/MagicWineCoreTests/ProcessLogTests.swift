import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct ProcessLogTests {
    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let wine: WineRuntime
        let bottle: Bottle
        var prefix: URL { store.prefixURL(for: bottle) }
        var bottleLogs: URL { ProcessLogs.bottleDirectory(bottle.id, paths: paths) }

        /// A fake Wine: no server holds the prefix (`-k` exits 1); `busy` keeps `-w` waiting.
        init() async throws {
            let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            self.paths = paths
            let executable = paths.root.appendingPathComponent("custom/bin/wine")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = """
            #!/bin/sh
            if [ "$1" = --version ]; then printf 'wine-11.0\\n'; exit 0; fi
            if [ "$1" = -k ]; then exit 1; fi
            if [ "$1" = -w ] && [ -f "$WINEPREFIX/busy" ]; then printf 'still serving\\n'; exec /bin/sleep 30; fi
            if [ "$1" = hold ]; then touch "$WINEPREFIX/holding"; exec /bin/sleep 30; fi
            exit 0
            """
            for url in [executable, executable.deletingLastPathComponent().appendingPathComponent("wineserver")] {
                try Data(script.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            store = BottleStore(paths: paths)
            wine = WineRuntime(paths: paths, store: store)
            bottle = try await store.create(name: "Logs", runtime: RuntimeDescriptor(executableURL: executable, version: "wine-11.0"))
        }

        func program(_ name: String) throws -> WindowsProgram {
            let url = prefix.appendingPathComponent("drive_c/" + name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("MZ".utf8).write(to: url)
            return WindowsProgram(name: name, executablePath: url.path)
        }

        func logs(in directory: URL) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".log") }.sorted()
        }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a log whose creation date orders it for retention.
    @discardableResult
    private static func makeLog(_ name: String, in directory: URL, age: TimeInterval, size: Int = 16) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x61, count: size).write(to: url)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: url.path)
        return url
    }

    @Test func successfulProbesLeaveNoLogsAndLaunchLogsAreNamedPerBottle() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        _ = try await fixture.wine.inspect(executableURL: fixture.bottle.runtime.executableURL)
        try await fixture.wine.stop(fixture.bottle)
        #expect(fixture.logs(in: fixture.bottleLogs).isEmpty)
        #expect(fixture.logs(in: ProcessLogs.libraryDirectory(paths: fixture.paths)).isEmpty)

        let result = try await fixture.wine.launch(try fixture.program("game.exe"), in: fixture.bottle)
        // A shortcut's server wait after `start /unix` is a probe too: one log per launch.
        _ = try await fixture.wine.launch(try fixture.program("Store.url"), in: fixture.bottle)
        let names = fixture.logs(in: fixture.bottleLogs)
        #expect(names.count == 2)
        #expect(result.logURL.deletingLastPathComponent() == fixture.bottleLogs)
        #expect(result.logURL.lastPathComponent.hasSuffix(" launch game.exe.log"))
        #expect(names.contains { $0.hasSuffix(" launch Store.url.log") })
        var status = stat()
        #expect(lstat(result.logURL.path, &status) == 0 && status.st_mode & 0o777 == 0o600)
        #expect(try String(contentsOf: result.logURL, encoding: .utf8).hasPrefix("Command: "))
        let entries = ProcessLogs.list(bottle: fixture.bottle.id, paths: fixture.paths)
        #expect(entries.map(\.operation) == ["launch", "launch"])
        #expect(Set(entries.compactMap(\.detail)) == ["game.exe", "Store.url"])
        #expect(fixture.logs(in: fixture.paths.logsDirectory).isEmpty)
    }

    @Test func failedOrTimedOutProbesKeepAReadableLog() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        try Data().write(to: fixture.prefix.appendingPathComponent("busy"))
        do {
            _ = try await fixture.wine.configureSynchronization(msyncEnabled: false, in: fixture.bottle)
            Issue.record("A live server must refuse the change.")
        } catch {
            let message = error.localizedDescription
            let path = try #require(message.range(of: "Log: ").map { String(message[$0.upperBound...]) })
            #expect(URL(fileURLWithPath: path).deletingLastPathComponent() == fixture.bottleLogs)
            let log = try String(contentsOfFile: path, encoding: .utf8)
            #expect(log.hasPrefix("Command: "))
            #expect(log.contains("still serving"))
        }
        #expect(fixture.logs(in: fixture.bottleLogs).count == 1)

        // A runtime that runs but reports no version leaves its inspection log.
        let silent = fixture.paths.root.appendingPathComponent("silent/bin/wine")
        try FileManager.default.createDirectory(at: silent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho not a version\n".utf8).write(to: silent)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: silent.path)
        await #expect(throws: MagicWineError.self) { try await fixture.wine.inspect(executableURL: silent) }
        let library = ProcessLogs.libraryDirectory(paths: fixture.paths)
        let names = fixture.logs(in: library)
        #expect(names.count == 1)
        #expect(try String(contentsOf: library.appendingPathComponent(try #require(names.first)), encoding: .utf8)
            .contains("not a version"))
    }

    /// Both log writers: the detached helper and the in-process fallback without it.
    @Test(arguments: [true, false])
    func floodingOutputIsCappedWithAMarkerAndInterleaved(detached: Bool) async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try ProcessLogFile.create(in: directory, operation: "exec", detail: "flood")
        // Far more than a pipe buffer: the child must never block on its output.
        // The error line is assembled at run time so the command header cannot match it.
        let script = "printf 'one\\n'; printf '0024:%sr:module:before cap\\n' er >&2; printf 'two\\n'; head -c 3000000 /dev/zero | tr '\\0' x"
        let operation = ProcessOperation(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                                         environment: ["PATH": "/usr/bin:/bin"], directory: nil,
                                         output: .log(file), timeout: 60, outputLimit: 1_000, detachedLogWriter: detached)
        let result = try await operation.run()
        #expect(result.exitCode == 0)
        let text = try String(contentsOf: result.logURL, encoding: .utf8)
        let output = String(text[try #require(text.range(of: "\n\n")).upperBound...])
        let kept = "one\n0024:err:module:before cap\ntwo\n"
        #expect(output.hasPrefix(kept + String(repeating: "x", count: 1_000 - kept.utf8.count) + "\n[MagicWine: log truncated after 1000 bytes"))
        #expect(output.filter { $0 == "x" }.count == 1_000 - kept.utf8.count)
        #expect(ProcessLogSummary.summary(at: result.logURL) == "0024:err:module:before cap")
        // The last writer's exit closes the log, which releases it for retention.
        for _ in 0..<100 where ProcessLogs.isActive(result.logURL) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!ProcessLogs.isActive(result.logURL))
    }

    @Test(arguments: [true, false])
    func outputOfExactlyTheLimitHasNoMarker(detached: Bool) async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (count, marked) in [(1_000, false), (1_001, true)] {
            let file = try ProcessLogFile.create(in: directory, operation: "exec", detail: "\(count)")
            let operation = ProcessOperation(executable: URL(fileURLWithPath: "/bin/sh"),
                                             arguments: ["-c", "head -c \(count) /dev/zero | tr '\\0' x"],
                                             environment: ["PATH": "/usr/bin:/bin"], directory: nil,
                                             output: .log(file), timeout: 60, outputLimit: 1_000, detachedLogWriter: detached)
            let result = try await operation.run()
            for _ in 0..<100 where ProcessLogs.isActive(result.logURL) { try await Task.sleep(for: .milliseconds(50)) }
            let text = try String(contentsOf: result.logURL, encoding: .utf8)
            let output = String(text[try #require(text.range(of: "\n\n")).upperBound...])
            #expect(output.hasPrefix(String(repeating: "x", count: 1_000)))
            #expect(output.contains("[MagicWine: log truncated") == marked)
            #expect(output.filter { $0 == "x" }.count == 1_000)
        }
    }

    /// A Windows child that outlives the direct process (and MagicWine) keeps logging: the
    /// helper owns the pipe and the log, and this process holds no descriptor of either.
    @Test func outputAfterTheDirectProcessExitsStillReachesTheLog() async throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try ProcessLogFile.create(in: directory, operation: "launch", detail: "launcher")
        let operation = ProcessOperation(executable: URL(fileURLWithPath: "/bin/sh"),
                                         arguments: ["-c", "echo first; (sleep 5; echo late) &"],
                                         environment: ["PATH": "/usr/bin:/bin"], directory: nil,
                                         output: .log(file), timeout: 60)
        let result = try await operation.run()
        let log = result.logURL.resolvingSymlinksInPath().path
        #expect(try String(contentsOf: result.logURL, encoding: .utf8).hasSuffix("first\n"))
        #expect(ProcessLogs.isActive(result.logURL))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let open = (0..<getdtablesize()).filter { descriptor in
            fcntl(descriptor, F_GETPATH, &path) == 0 &&
                String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == log
        }
        #expect(open.isEmpty)
        for _ in 0..<300 where ProcessLogs.isActive(result.logURL) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!ProcessLogs.isActive(result.logURL))
        #expect(try String(contentsOf: result.logURL, encoding: .utf8).hasSuffix("first\nlate\n"))
    }

    @Test func retentionKeepsNewestLogsWithinBudgetAndRunningOperations() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limit = ProcessLogs.retention.maximumCount
        for index in 0..<(limit + 10) {
            try Self.makeLog("log-\(index).log", in: directory, age: TimeInterval(index * 60))
        }
        // An old log still held open by a running operation survives.
        let running = try ProcessLogFile.create(in: directory, operation: "launch", detail: "game.exe")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: running.url.path)
        try Data("not a log".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        ProcessLogs.prune(directory: directory)
        var remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(remaining.contains(running.url.lastPathComponent))
        #expect(remaining.contains("notes.txt"))
        #expect(remaining.count == limit + 2)
        for index in 0..<limit { #expect(remaining.contains("log-\(index).log")) }

        running.close()
        remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        #expect(!remaining.contains(running.url.lastPathComponent))

        // Size budget: sparse logs, newest first, until the budget is exceeded.
        let sized = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sized) }
        let hundred = 100 * 1_048_576
        for index in 0..<4 {
            let url = try Self.makeLog("big-\(index).log", in: sized, age: TimeInterval(index * 60), size: 1)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(hundred))
            try handle.close()
        }
        ProcessLogs.prune(directory: sized)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: sized.path)) == ["big-0.log", "big-1.log"])
    }

    @Test func legacyFlatLogsArePrunedPerBottleInPlace() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let logs = paths.logsDirectory
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let bottle = UUID()
        let limit = ProcessLogs.retention.maximumCount
        for index in 0..<(limit + 5) {
            try Self.makeLog("\(bottle.uuidString)-wineserver-\(UUID().uuidString).log", in: logs, age: TimeInterval((index + 1) * 60))
        }
        let newest = try Self.makeLog("\(bottle.uuidString)-wine-\(UUID().uuidString).log", in: logs, age: 1)
        for index in 0..<3 { try Self.makeLog("wine-version-\(UUID().uuidString).log", in: logs, age: TimeInterval(index)) }

        ProcessLogs.prune(paths: paths)
        let names = try FileManager.default.contentsOfDirectory(atPath: logs.path)
        #expect(names.filter { $0.hasPrefix(bottle.uuidString) }.count == limit)
        #expect(names.filter { $0.hasPrefix("wine-version-") }.count == 3)
        #expect(!FileManager.default.fileExists(atPath: logs.appendingPathComponent("Bottles").path))
        let entries = ProcessLogs.list(bottle: bottle, paths: paths)
        #expect(entries.count == limit)
        #expect(entries.first?.url == newest)
        #expect(entries.first?.operation == "wine")
    }

    @Test func trashingABottleRemovesOnlyItsLogs() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ApplicationPaths(root: root)
        let (trashed, kept) = (UUID(), UUID())
        for id in [trashed, kept] {
            let folder = ProcessLogs.bottleDirectory(id, paths: paths)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("dxvk"), withIntermediateDirectories: true)
            _ = try ProcessLogFile.record(Data("log".utf8), in: folder, operation: "launch", detail: "game.exe")
            try Self.makeLog("\(id.uuidString)-wine-\(UUID().uuidString).log", in: paths.logsDirectory, age: 60)
            try FileManager.default.createDirectory(at: paths.logsDirectory.appendingPathComponent("\(id.uuidString)-dxmt"),
                                                    withIntermediateDirectories: true)
        }
        try ProcessLogs.removeLogs(forBottle: trashed, paths: paths)
        #expect(!FileManager.default.fileExists(atPath: ProcessLogs.bottleDirectory(trashed, paths: paths).path))
        let names = try FileManager.default.contentsOfDirectory(atPath: paths.logsDirectory.path)
        #expect(!names.contains { $0.hasPrefix(trashed.uuidString) })
        #expect(names.filter { $0.hasPrefix(kept.uuidString) }.count == 2)
        #expect(ProcessLogs.list(bottle: kept, paths: paths).count == 2)
    }
}
