import Foundation
import Testing
@testable import MagicWineCore

/// The `MagicWineError` a body throws, for assertions on its kind, log, and actions.
func thrownError(_ body: () async throws -> Void) async -> MagicWineError? {
    do { try await body() } catch { return error as? MagicWineError }
    return nil
}

struct ErrorReportingTests {
    private static func temporaryPaths() throws -> ApplicationPaths {
        let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString))
        try paths.prepare()
        return paths
    }

    private static func bottle(initialized: Bool, graphics: GraphicsConfiguration = .init()) -> Bottle {
        Bottle(name: "Errors", runtime: RuntimeDescriptor(executableURL: URL(fileURLWithPath: "/opt/wine/bin/wine"), version: "wine-11.0"),
               isInitialized: initialized, graphics: graphics)
    }

    private static var olderDXMT: GraphicsConfiguration {
        GraphicsConfiguration(backend: .dxmt, componentID: DXMTInstallation.retainedComponentIDs.first)
    }

    @Test func timeoutReportsItsLogOutsideTheMessage() async throws {
        let paths = try Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let error = try #require(await thrownError {
            _ = try await RuntimeInstallation.tool("/bin/sleep", arguments: ["10"], paths: paths, name: "sleep", timeout: 0.2)
        })
        guard case .timedOut = error else { Issue.record("Unexpected error: \(error)"); return }
        let log = try #require(error.logURL)
        #expect(FileManager.default.fileExists(atPath: log.path))
        #expect(!(error.errorDescription ?? "").contains(log.path))
        #expect(error.recoveryActions == [.showLog(log), .retry])
    }

    @Test func graphicsOnAnUninitializedBottleAsksForSetup() async throws {
        let paths = try Self.temporaryPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = BottleStore(paths: paths)
        let wine = WineRuntime(paths: paths, store: store)
        let bottle = try await store.create(name: "Uninitialized", runtime: Self.bottle(initialized: false).runtime)
        let error = try #require(await thrownError {
            _ = try await wine.configureGraphics(.dxvk, in: bottle, acceptExperimental: true)
        })
        guard case .notInitialized = error else { Issue.record("Unexpected error: \(error)"); return }
        #expect(error.recoveryActions == [.retrySetup])
        #expect(error.recoveryActions.allSatisfy { $0.isAvailable(for: bottle) })
        // Without consent nothing is checked or changed, and the consent is named.
        let consent = try #require(await thrownError { _ = try await wine.configureGraphics(.dxvk, in: bottle) })
        #expect(consent.recoveryActions == [.giveConsent(.experimentalGraphics)])
        #expect(try await store.current(bottle) == bottle)
    }

    @Test func componentActionsApplyOnlyToBottlesThatCanUseThem() {
        let actions = MagicWineError.componentInvalid("The bottle's graphics DLLs are missing or changed.").recoveryActions
        #expect(actions == [.restoreStandardGraphics, .updateGraphicsComponent])
        let older = Self.bottle(initialized: true, graphics: Self.olderDXMT)
        #expect(actions.allSatisfy { $0.isAvailable(for: older) })
        let current = Self.bottle(initialized: true, graphics: GraphicsConfiguration(backend: .dxmt, componentID: DXMTInstallation.componentID))
        #expect(actions.filter { $0.isAvailable(for: current) } == [.restoreStandardGraphics])
        for bottle in [Self.bottle(initialized: true), Self.bottle(initialized: false, graphics: Self.olderDXMT)] {
            #expect(actions.filter { $0.isAvailable(for: bottle) }.isEmpty)
        }
        #expect(!RecoveryAction.retrySetup.isAvailable(for: current))
        // A program's own graphics choice is fixed on that program, never by changing the bottle.
        let program = UUID()
        let refused = MagicWineError.programGraphicsUnavailable("DXVK needs the bottle's files.", programID: program)
        #expect(refused.recoveryActions == [.chooseProgramGraphics(programID: program)])
        #expect(CommandLineErrorReport.render(refused, bottle: current).contains(
            "magicwine program \(current.id.uuidString) \(program.uuidString) --graphics default"))
    }

    @Test func wrappedFailuresKeepRecoveryAndUseTheOperationLog() {
        let operationLog = URL(fileURLWithPath: "/tmp/dependencies.log")
        let busy = MagicWineError.busy("This bottle's Windows programs are running.", reason: .programsRunning)
        #expect(busy.withLog(operationLog).recoveryActions == [.showLog(operationLog), .stopBottle])
        let failed = MagicWineError.failed("DXVK installation failed.", logURL: operationLog,
                                           underlying: MagicWineError.componentInvalid("Unsupported DXVK component."))
        #expect(failed.recoveryActions == [.showLog(operationLog), .restoreStandardGraphics, .updateGraphicsComponent])
        let exited = MagicWineError.processFailed(exitCode: 3, logURL: URL(fileURLWithPath: "/tmp/server.log"))
        #expect(exited.withLog(operationLog).logURL == operationLog)
        #expect(MagicWineError.integrityFailure("Mismatch.").recoveryActions.isEmpty)
    }

    @Test func commandLineReportPrintsTheLogAndACommandPerAction() {
        let id = UUID()
        let msync = MagicWineError.runtimeIncompatible("MSync requires the updated MagicWine-managed Wine runtime.", remedy: .updateWine)
        #expect(CommandLineErrorReport.render(msync, bottleID: id).components(separatedBy: "\n") == [
            "error: MSync requires the updated MagicWine-managed Wine runtime.",
            "hint: run: magicwine install-wine --accept-unsigned && magicwine runtime upgrade \(id.uuidString)",
        ])

        let log = URL(fileURLWithPath: "/tmp/server.log")
        let busy = MagicWineError.busy("This bottle's Wine server is still running.", reason: .programsRunning, logURL: log)
        #expect(CommandLineErrorReport.render(busy, bottleID: id, invocation: "magicwine --root /tmp/library")
            .components(separatedBy: "\n") == [
                "error: This bottle's Wine server is still running.",
                "log: /tmp/server.log",
                "hint: run: magicwine --root /tmp/library stop \(id.uuidString)",
            ])

        // Graphics commands appear only when they apply to the named bottle.
        let component = MagicWineError.componentInvalid("The bottle's graphics DLLs are missing or changed.")
        let older = Self.bottle(initialized: true, graphics: Self.olderDXMT)
        let hints = CommandLineErrorReport.render(component, bottle: older).components(separatedBy: "\n").dropFirst()
        #expect(Array(hints) == ["hint: run: magicwine graphics \(older.id.uuidString) standard",
                                 "hint: run: magicwine graphics \(older.id.uuidString) dxmt --update --accept-experimental"])
        #expect(!CommandLineErrorReport.render(component, bottle: Self.bottle(initialized: true)).contains("hint:"))

        #expect(CommandLineErrorReport.render(MagicWineError.invalidBottle) == "error: The bottle is missing or its metadata is invalid.")
        #expect(CommandLineErrorReport.render(CocoaError(.fileNoSuchFile)).hasPrefix("error: "))
    }
}
