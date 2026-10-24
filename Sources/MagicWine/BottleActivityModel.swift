import Foundation
import MagicWineCore
import Observation

struct BottleActivity {
    var title: String?
    var canStop = false
    var isStopping = false
    var error: PresentedError?
    var logURL: URL?
    var graphicsProgress: GraphicsSetupProgress?
    var graphicsSetupID: UUID?
    var runningLaunches: Set<UUID> = []
    var notices: [BottleNotice] = []
    var isChangingHUD = false
    var hasRunningPrograms: Bool { !runningLaunches.isEmpty }
}

extension BottleActivity {
    /// Changes Wine's prefix, runtime, or the bottle directory itself (graphics, MSync, Retina,
    /// installers, Wine update, winecfg, setup, Trash). Running programs hold the prefix open.
    var blocksPrefixMutation: Bool { title != nil || hasRunningPrograms || isStopping }

    /// Edits only MagicWine's bottle metadata and shortcut bookkeeping under the bottle lock
    /// (refresh/add/remove programs, reload). Safe while Windows programs run.
    var blocksLibraryEdit: Bool { title != nil || isStopping }

    /// Starting another program may overlap running ones, but not an exclusive operation.
    var blocksLaunch: Bool { title != nil || isStopping }

    /// Stop Windows Processes (toolbar and menu): any set-up bottle without an exclusive
    /// operation, since programs started elsewhere may run, and operations that can stop.
    func allowsStop(of bottle: Bottle) -> Bool {
        !isStopping && (canStop || (title == nil && bottle.isInitialized))
    }
}

/// A dismissible, non-error status for one bottle, tied to one specific process log.
struct BottleNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let logURL: URL
}

/// The log of one running launch; `id` is the launch.
struct LiveLog: Identifiable {
    let id: UUID
    let programID: UUID
    let programName: String
    let url: URL
}

/// Per-bottle operation state: exclusive operations (`perform`), launches and their live
/// logs, Stop, and the bottle operations that run Wine or edit the program list.
@Observable
@MainActor
final class BottleActivityModel {
    private(set) var activities: [UUID: BottleActivity] = [:]
    /// Logs of launches that are still running, per bottle, delivered when each started.
    private(set) var liveLogs: [UUID: [LiveLog]] = [:]
    /// A log to open in a viewer window, consumed by the main window (diagnostic launches).
    var logToShow: URL?

    @ObservationIgnored private let wine: WineRuntime
    @ObservationIgnored private let store: BottleStore
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let notices: NoticeModel

    init(wine: WineRuntime, store: BottleStore, library: LibraryModel, notices: NoticeModel) {
        self.wine = wine
        self.store = store
        self.library = library
        self.notices = notices
    }

    func activity(for bottle: Bottle) -> BottleActivity {
        activities[bottle.id] ?? BottleActivity()
    }

    func liveLogs(for bottle: Bottle) -> [LiveLog] { liveLogs[bottle.id] ?? [] }

    /// Changes one bottle's state; with `ifPresent`, a bottle without state is left alone.
    func update(_ id: UUID, ifPresent: Bool = false, _ change: (inout BottleActivity) -> Void) {
        guard var state = activities[id] ?? (ifPresent ? nil : BottleActivity()) else { return }
        change(&state)
        activities[id] = state
    }

    /// Runs one exclusive operation: refused while `blocksPrefixMutation` (or, for metadata
    /// edits with `allowsRunningPrograms`, `blocksLibraryEdit`); its title shows until it ends.
    func perform(in bottle: Bottle, title: String, canStop: Bool = false,
                 allowsRunningPrograms: Bool = false,
                 operation: @escaping @MainActor () async throws -> OperationResult?) {
        var state = activity(for: bottle)
        guard !(allowsRunningPrograms ? state.blocksLibraryEdit : state.blocksPrefixMutation) else { return }
        state.title = title
        state.canStop = canStop
        state.error = nil
        activities[bottle.id] = state
        Task {
            do {
                if let result = try await operation() { recordLog(result.logURL, for: bottle.id) }
            } catch {
                recordError(error, for: bottle.id)
            }
            // A deleted bottle no longer needs operation state.
            guard library.contains(bottle.id) else { return }
            var latest = activity(for: bottle)
            latest.title = nil
            latest.canStop = false
            latest.graphicsProgress = nil
            latest.graphicsSetupID = nil
            activities[bottle.id] = latest
        }
    }

    func initialize(_ bottle: Bottle) {
        perform(in: bottle, title: "Setting up Windows environment…", canStop: true) {
            let initialization = try await self.wine.initialize(bottle)
            self.library.replace(initialization.bottle)
            return initialization.result
        }
    }

    func install(_ url: URL, in bottle: Bottle) {
        let bottle = library.current(bottle)
        guard bottle.isInitialized else {
            notices.post(AppNotice(title: "Set Up This Bottle First", message: "Use Retry Setup for \(bottle.name), then open the installer again."))
            return
        }
        guard !activity(for: bottle).blocksPrefixMutation else {
            notices.post(AppNotice(title: "Bottle Is Busy", message: "Wait for the operation in \(bottle.name) to finish, or stop the bottle, before opening another installer."))
            return
        }
        perform(in: bottle, title: "Installing \(url.lastPathComponent)…", canStop: true) {
            let result = try await self.wine.install(url, in: bottle)
            self.recordLog(result.logURL, for: bottle.id)
            let updated = try await self.store.discoverPrograms(in: self.library.current(bottle))
            self.library.replace(updated)
            return result
        }
    }

    func addProgram(_ url: URL, to bottle: Bottle) {
        perform(in: bottle, title: "Adding program…", allowsRunningPrograms: true) {
            let updated = try await self.store.registerProgram(in: self.library.current(bottle), executableURL: url)
            self.library.replace(updated)
            return nil
        }
    }

    func refreshPrograms(in bottle: Bottle) {
        perform(in: bottle, title: "Finding Windows shortcuts…", allowsRunningPrograms: true) {
            let updated = try await self.store.discoverPrograms(in: self.library.current(bottle))
            self.library.replace(updated)
            return nil
        }
    }

    func removeProgram(_ program: WindowsProgram, in bottle: Bottle) {
        perform(in: bottle, title: "Removing shortcut…", allowsRunningPrograms: true) {
            let updated = try await self.store.removeProgram(id: program.id, in: self.library.current(bottle))
            self.library.replace(updated)
            return nil
        }
    }

    func configure(_ bottle: Bottle) {
        perform(in: bottle, title: "Wine configuration is open…", canStop: true) {
            try await self.wine.configure(bottle)
        }
    }

    /// `diagnostics` is a one-off launch with a diagnostic `WINEDEBUG`; nothing is saved,
    /// and its log is offered when the program ends.
    func launch(_ program: WindowsProgram, in bottle: Bottle, diagnostics: Bool = false) {
        let bottle = library.current(bottle)
        var state = activity(for: bottle)
        guard bottle.isInitialized, !state.blocksLaunch else { return }
        // A launcher may stay alive in the Windows tray. Its lifetime must not
        // prevent another launch from reopening it or starting a game.
        let launchID = UUID()
        state.runningLaunches.insert(launchID)
        state.error = nil
        activities[bottle.id] = state
        Task {
            do {
                let result = try await wine.launch(program, in: bottle, diagnostics: diagnostics) { start in
                    Task { @MainActor in
                        self.startLiveLog(LiveLog(id: launchID, programID: program.id, programName: program.name,
                                                  url: start.logURL), in: bottle.id)
                        // Steam or a game can run for hours; warn as soon as it starts.
                        guard !start.warnings.isEmpty else { return }
                        self.recordNotice(BottleNotice(
                            title: "\(program.name) started with reduced compatibility",
                            message: start.warnings.joined(separator: "\n\n"), logURL: start.logURL), for: bottle.id)
                    }
                }
                recordLog(result.logURL, for: bottle.id)
                if diagnostics {
                    let summary = result.exitCode == 0 ? "" : "\n\n" + (ProcessLogSummary.summary(at: result.logURL) ?? "")
                    recordNotice(BottleNotice(
                        title: "Diagnostic launch of \(program.name) ended (exit code \(result.exitCode))",
                        message: "The log lists DLL load decisions (+loaddll), exceptions (+seh), and process starts (+process) in addition to Wine errors. Review it for personal paths before sharing." + summary,
                        logURL: result.logURL), for: bottle.id)
                    logToShow = result.logURL
                } else if result.exitCode != 0 {
                    // A normal quit with a nonzero code is status, not an operation failure.
                    let summary = ProcessLogSummary.summary(at: result.logURL)
                        ?? "Wine reported no errors at the end of the log. Many games and launchers use nonzero codes for normal exits."
                    recordNotice(BottleNotice(title: "\(program.name) exited with code \(result.exitCode)",
                                              message: summary, logURL: result.logURL), for: bottle.id)
                }
            } catch {
                recordError(error, for: bottle.id)
            }
            endLiveLog(launchID, in: bottle.id)
            guard library.contains(bottle.id) else { return }
            var latest = activity(for: bottle)
            latest.runningLaunches.remove(launchID)
            activities[bottle.id] = latest
        }
    }

    func stop(_ bottle: Bottle) {
        var state = activity(for: bottle)
        guard !state.isStopping, state.graphicsSetupID == nil else { return }
        state.isStopping = true
        activities[bottle.id] = state
        Task {
            do {
                try await wine.stop(bottle)
            } catch {
                recordError(error, for: bottle.id)
            }
            var latest = activity(for: bottle)
            latest.isStopping = false
            activities[bottle.id] = latest
        }
    }

    func trash(_ bottle: Bottle) {
        perform(in: bottle, title: "Stopping and moving bottle to Trash…") {
            _ = try await self.wine.stop(bottle)
            try await self.store.delete(bottle)
            self.library.remove(bottle.id)
            self.activities.removeValue(forKey: bottle.id)
            return nil
        }
    }

    func dismissError(for bottle: Bottle) {
        var state = activity(for: bottle)
        state.error = nil
        activities[bottle.id] = state
    }

    func dismissNotice(_ id: UUID, for bottle: Bottle) {
        guard var state = activities[bottle.id] else { return }
        state.notices.removeAll { $0.id == id }
        activities[bottle.id] = state
    }

    func recordNotice(_ notice: BottleNotice, for id: UUID) {
        guard library.contains(id) else { return }
        var state = activities[id] ?? BottleActivity()
        // Keep the dashboard compact when a launcher is reopened repeatedly.
        state.notices = Array((state.notices + [notice]).suffix(4))
        activities[id] = state
    }

    func recordLog(_ url: URL, for id: UUID) {
        var state = activities[id] ?? BottleActivity()
        state.logURL = url
        activities[id] = state
    }

    func recordError(_ error: Error, for id: UUID) {
        var state = activities[id] ?? BottleActivity()
        if let wineError = error as? MagicWineError, case .stopped(let logURL) = wineError {
            state.logURL = logURL
            state.error = nil
        } else {
            let presented = PresentedError(error)
            state.error = presented
            if let logURL = presented.logURL { state.logURL = logURL }
        }
        activities[id] = state
    }

    private func startLiveLog(_ log: LiveLog, in bottleID: UUID) {
        // The launch may already have ended before this start callback arrived.
        guard activities[bottleID]?.runningLaunches.contains(log.id) == true else { return }
        liveLogs[bottleID, default: []].append(log)
    }

    private func endLiveLog(_ launchID: UUID, in bottleID: UUID) {
        liveLogs[bottleID]?.removeAll { $0.id == launchID }
        if liveLogs[bottleID]?.isEmpty == true { liveLogs[bottleID] = nil }
    }
}
