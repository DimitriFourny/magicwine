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
    /// Running launches by program ID. A program can have several: a tray launcher such as
    /// Steam may be launched again to reopen it while its first launch still runs.
    var running: [UUID: RunningProgram] = [:]
    var notices: [BottleNotice] = []
    var isChangingHUD = false
    var hasRunningPrograms: Bool { !running.isEmpty }

    func isRunning(_ program: WindowsProgram) -> Bool { running[program.id] != nil }

    /// Names of the running programs, for the sidebar and dashboard.
    var runningProgramNames: [String] {
        running.values.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// One program's overlapping launches and its play session.
struct RunningProgram {
    var name: String
    var launches: Set<UUID> = []
    /// `ProcessInfo.systemUptime` when the first of these launches started its process (sleep
    /// is not counted); `nil` until then.
    var startedAt: TimeInterval?
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
    /// `completion` runs after the title is cleared, with whether the operation succeeded.
    func perform(in bottle: Bottle, title: String, canStop: Bool = false,
                 allowsRunningPrograms: Bool = false,
                 operation: @escaping @MainActor () async throws -> OperationResult?,
                 completion: (@MainActor (_ succeeded: Bool) -> Void)? = nil) {
        var state = activity(for: bottle)
        guard !(allowsRunningPrograms ? state.blocksLibraryEdit : state.blocksPrefixMutation) else { return }
        state.title = title
        state.canStop = canStop
        state.error = nil
        activities[bottle.id] = state
        Task {
            var succeeded = true
            do {
                if let result = try await operation() { recordLog(result.logURL, for: bottle.id) }
            } catch {
                succeeded = false
                recordError(error, for: bottle.id)
            }
            // A deleted bottle no longer needs operation state.
            guard library.contains(bottle.id) else {
                completion?(false)
                return
            }
            var latest = activity(for: bottle)
            latest.title = nil
            latest.canStop = false
            latest.graphicsProgress = nil
            latest.graphicsSetupID = nil
            activities[bottle.id] = latest
            completion?(succeeded)
        }
    }

    /// `completion` runs after setup ended, with whether it succeeded.
    func initialize(_ bottle: Bottle, completion: (@MainActor (_ succeeded: Bool) -> Void)? = nil) {
        perform(in: bottle, title: localized("Setting up Windows environment…"), canStop: true, operation: {
            let initialization = try await self.wine.initialize(bottle)
            self.library.replace(initialization.bottle)
            return initialization.result
        }, completion: completion)
    }

    func install(_ url: URL, in bottle: Bottle) {
        let bottle = library.current(bottle)
        guard bottle.isInitialized else {
            notices.post(AppNotice(title: localized("Set Up This Bottle First"), message: localized("Use Retry Setup for \(bottle.name), then open the installer again.")))
            return
        }
        guard !activity(for: bottle).blocksPrefixMutation else {
            notices.post(AppNotice(title: localized("Bottle Is Busy"), message: localized("Wait for the operation in \(bottle.name) to finish, or stop the bottle, before opening another installer.")))
            return
        }
        perform(in: bottle, title: localized("Installing \(url.lastPathComponent)…"), canStop: true) {
            let result = try await self.wine.install(url, in: bottle)
            self.recordLog(result.logURL, for: bottle.id)
            let updated = try await self.store.discoverPrograms(in: self.library.current(bottle))
            self.library.replace(updated)
            return result
        }
    }

    func addProgram(_ url: URL, to bottle: Bottle) {
        addPrograms([url], to: bottle)
    }

    /// Registers EXE, LNK, or URL files in one library edit, in place and in order; allowed
    /// while programs run. Stops at the first file the store refuses.
    func addPrograms(_ urls: [URL], to bottle: Bottle) {
        let bottle = library.current(bottle)
        guard bottle.isInitialized else {
            notices.post(AppNotice(title: localized("Set Up This Bottle First"), message: localized("Use Retry Setup for \(bottle.name), then add the program again.")))
            return
        }
        guard !activity(for: bottle).blocksLibraryEdit else {
            notices.post(AppNotice(title: localized("Bottle Is Busy"), message: localized("Wait for the operation in \(bottle.name) to finish, or stop the bottle, before adding programs.")))
            return
        }
        perform(in: bottle, title: urls.count == 1 ? localized("Adding program…") : localized("Adding programs…"), allowsRunningPrograms: true) {
            for url in urls {
                let updated = try await self.store.registerProgram(in: self.library.current(bottle), executableURL: url)
                self.library.replace(updated)
            }
            return nil
        }
    }

    func refreshPrograms(in bottle: Bottle) {
        perform(in: bottle, title: localized("Finding Windows shortcuts…"), allowsRunningPrograms: true) {
            let updated = try await self.store.discoverPrograms(in: self.library.current(bottle))
            self.library.replace(updated)
            return nil
        }
    }

    func removeProgram(_ program: WindowsProgram, in bottle: Bottle) {
        perform(in: bottle, title: localized("Removing shortcut…"), allowsRunningPrograms: true) {
            let updated = try await self.store.removeProgram(id: program.id, in: self.library.current(bottle))
            self.library.replace(updated)
            return nil
        }
    }

    func configure(_ bottle: Bottle) {
        perform(in: bottle, title: localized("Wine configuration is open…"), canStop: true) {
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
        state.running[program.id, default: RunningProgram(name: program.name)].launches.insert(launchID)
        state.error = nil
        activities[bottle.id] = state
        Task {
            do {
                let result = try await wine.launch(program, in: bottle, diagnostics: diagnostics) { start in
                    Task { @MainActor in
                        self.started(launchID, of: program, in: bottle, log: start.logURL)
                        // Steam or a game can run for hours; warn as soon as it starts.
                        guard !start.warnings.isEmpty else { return }
                        self.recordNotice(BottleNotice(
                            title: localized("\(program.name) started with reduced compatibility"),
                            message: start.warnings.joined(separator: "\n\n"), logURL: start.logURL), for: bottle.id)
                    }
                }
                recordLog(result.logURL, for: bottle.id)
                if diagnostics {
                    let summary = result.exitCode == 0 ? "" : "\n\n" + (ProcessLogSummary.summary(at: result.logURL) ?? "")
                    recordNotice(BottleNotice(
                        title: localized("Diagnostic launch of \(program.name) ended (exit code \(Int(result.exitCode)))"),
                        message: localized("The log lists DLL load decisions (+loaddll), exceptions (+seh), and process starts (+process) in addition to Wine errors. Review it for personal paths before sharing.") + summary,
                        logURL: result.logURL), for: bottle.id)
                    logToShow = result.logURL
                } else if result.exitCode != 0 {
                    // A normal quit with a nonzero code is status, not an operation failure.
                    let summary = ProcessLogSummary.summary(at: result.logURL)
                        ?? localized("Wine reported no errors at the end of the log. Many games and launchers use nonzero codes for normal exits.")
                    recordNotice(BottleNotice(title: localized("\(program.name) exited with code \(Int(result.exitCode))"),
                                              message: summary, logURL: result.logURL), for: bottle.id)
                }
            } catch {
                recordError(error, for: bottle.id)
            }
            endLiveLog(launchID, in: bottle.id)
            ended(launchID, of: program, in: bottle)
        }
    }

    /// A launch's process started: follow its log, record the launch, and begin the
    /// program's play session unless an earlier launch of it is still running.
    private func started(_ launchID: UUID, of program: WindowsProgram, in bottle: Bottle, log: URL) {
        // The launch may already have ended before this start callback arrived.
        guard activities[bottle.id]?.running[program.id]?.launches.contains(launchID) == true else { return }
        liveLogs[bottle.id, default: []].append(LiveLog(id: launchID, programID: program.id,
                                                        programName: program.name, url: log))
        update(bottle.id) { state in
            if state.running[program.id]?.startedAt == nil {
                state.running[program.id]?.startedAt = ProcessInfo.processInfo.systemUptime
            }
        }
        let date = Date()
        saveLibraryMetadata(of: bottle) { try await $0.recordLaunch(of: program.id, at: date, in: bottle) }
    }

    /// The program's last running launch ends its play session, which is added to its play time.
    private func ended(_ launchID: UUID, of program: WindowsProgram, in bottle: Bottle) {
        guard library.contains(bottle.id) else { return }
        var latest = activity(for: bottle)
        guard var entry = latest.running[program.id] else { return }
        entry.launches.remove(launchID)
        latest.running[program.id] = entry.launches.isEmpty ? nil : entry
        activities[bottle.id] = latest
        guard entry.launches.isEmpty, let startedAt = entry.startedAt else { return }
        let duration = max(0, ProcessInfo.processInfo.systemUptime - startedAt)
        saveLibraryMetadata(of: bottle) { try await $0.addPlayTime(duration, to: program.id, in: bottle) }
    }

    /// Play history is metadata only, like Add Program: saved while programs run.
    private func saveLibraryMetadata(of bottle: Bottle,
                                     _ transition: @escaping @MainActor (BottleStore) async throws -> Bottle) {
        Task {
            do {
                library.replace(try await transition(store))
            } catch {
                recordError(error, for: bottle.id)
            }
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
        perform(in: bottle, title: localized("Stopping and moving bottle to Trash…")) {
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

    private func endLiveLog(_ launchID: UUID, in bottleID: UUID) {
        liveLogs[bottleID]?.removeAll { $0.id == launchID }
        if liveLogs[bottleID]?.isEmpty == true { liveLogs[bottleID] = nil }
    }
}
