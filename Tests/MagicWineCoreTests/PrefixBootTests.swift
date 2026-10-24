import Foundation
import Testing
@testable import MagicWineCore

/// Wine applies `PendingFileRenameOperations` when the first process of a new server
/// session runs `wineboot --init`. The fake Wine does the same at every program start, as
/// a new session would, and leaves `rewritten-at-launch` when that overwrote a prefix DLL.
struct PrefixBootTests {
    private struct Fixture {
        let paths: ApplicationPaths
        let store: BottleStore
        let wine: WineRuntime
        let bottle: Bottle
        var prefix: URL { store.prefixURL(for: bottle) }
        var directory: URL { prefix.deletingLastPathComponent() }
        var cpu: URL { prefix.appendingPathComponent("drive_c/windows/system32/wow64cpu.dll") }

        init() async throws {
            let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent(UUID().uuidString))
            try paths.prepare()
            self.paths = paths
            let executable = paths.root.appendingPathComponent("custom/bin/wine")
            try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            let script = #"""
            #!/bin/sh
            system32="$WINEPREFIX/drive_c/windows/system32"
            boot() {
              grep -q PendingFileRenameOperations "$WINEPREFIX/system.reg" 2>/dev/null || return 1
              mv "$system32/dll1.tmp" "$system32/wow64cpu.dll"
              printf 'WINE REGISTRY Version 2\n\n' > "$WINEPREFIX/system.reg"
            }
            case "$1" in
              --version) printf 'wine-11.0\n' ;;
              wineboot)
                if [ "$2" = --init ]; then boot && echo boot >> "$WINEPREFIX/../boots"; exit 0; fi
                # `-u` while Wine's services map the old DLL: stage it for the next session.
                mkdir -p "$system32"; printf 'stock' > "$system32/wow64cpu.dll"; printf 'updated' > "$system32/dll1.tmp"
                [ -f "$WINEPREFIX/user.reg" ] || printf 'WINE REGISTRY Version 2\n\n' > "$WINEPREFIX/user.reg"
                printf '%s\n' 'WINE REGISTRY Version 2' '' \
                  '[System\\ControlSet001\\Control\\Session Manager] 1792842028' \
                  '"PendingFileRenameOperations"=str(7):"\\??\\C:\\windows\\system32\\dll1.tmp\0!\\??\\C:\\windows\\system32\\wow64cpu.dll\0"' \
                  > "$WINEPREFIX/system.reg" ;;
              hold) touch "$WINEPREFIX/holding"; exec /bin/sleep 30 ;;
              *.exe) boot && touch "$WINEPREFIX/../rewritten-at-launch"
                     cat "$system32/wow64cpu.dll" > "$WINEPREFIX/../program-saw" ;;
            esac
            exit 0
            """#
            for url in [executable, executable.deletingLastPathComponent().appendingPathComponent("wineserver")] {
                try Data(script.utf8).write(to: url)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            store = BottleStore(paths: paths)
            wine = WineRuntime(paths: paths, store: store)
            bottle = try await store.create(name: "Boot", runtime: RuntimeDescriptor(executableURL: executable, version: "wine-11.0"))
        }

        func program() throws -> WindowsProgram {
            let url = prefix.appendingPathComponent("drive_c/game.exe")
            try Data("MZ".utf8).write(to: url)
            return WindowsProgram(name: "Game", executablePath: url.path)
        }

        /// An initialized prefix whose last update still owes the next session a DLL move,
        /// as bottles set up before initialization finished that work have.
        func stageUpdate() async throws -> Bottle {
            _ = try await wine.run(arguments: ["wineboot", "-u"], in: bottle)
            return try await store.markInitialized(bottle)
        }

        func text(_ name: String) -> String? { try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) }
        var boots: Int { text("boots")?.split(separator: "\n").count ?? 0 }

        func remove() { try? FileManager.default.removeItem(at: paths.root) }
    }

    @Test func initializeLeavesNoDLLMoveForTheFirstLaunch() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let initialized = try await fixture.wine.initialize(fixture.bottle).bottle
        #expect(fixture.boots == 1)
        #expect(try String(contentsOf: fixture.cpu, encoding: .utf8) == "updated")
        #expect(try !PrefixBoot.hasPendingRenames(prefix: fixture.prefix))

        _ = try await fixture.wine.launch(try fixture.program(), in: initialized)
        #expect(fixture.text("rewritten-at-launch") == nil)
        #expect(fixture.text("program-saw") == "updated")
        // Nothing left to boot: launches do not start an extra session.
        #expect(fixture.boots == 1)
    }

    @Test func idleLaunchFinishesAnOwedDLLMoveBeforePreparingThePrefix() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let bottle = try await fixture.stageUpdate()
        #expect(fixture.boots == 0)

        _ = try await fixture.wine.launch(try fixture.program(), in: bottle)
        #expect(fixture.boots == 1)
        #expect(fixture.text("rewritten-at-launch") == nil)
        #expect(fixture.text("program-saw") == "updated")
    }

    @Test func liveSessionIsNeverRebootedForAnOwedDLLMove() async throws {
        let fixture = try await Fixture()
        defer { fixture.remove() }
        let bottle = try await fixture.store.markInitialized(fixture.bottle)
        let finished = Task { _ = try? await fixture.wine.run(arguments: ["hold"], in: bottle); return true }
        defer { finished.cancel() }
        let marker = fixture.prefix.appendingPathComponent("holding")
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: marker.path))
        _ = try await fixture.stageUpdate()

        // The running program's session already booted and keeps running; Wine applies
        // the move when the next session starts, and a later idle launch finishes it first.
        _ = try await fixture.wine.run(arguments: ["other"], in: bottle)
        #expect(fixture.boots == 0)
        #expect(try PrefixBoot.hasPendingRenames(prefix: fixture.prefix))
        _ = try await fixture.wine.stop(bottle)
        #expect(await finished.value)
    }
}
