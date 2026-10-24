import AppKit
import Combine
import Foundation
import MagicWineCore
import UniformTypeIdentifiers

struct BottleActivity {
    var title: String?
    var canStop = false
    var isStopping = false
    var error: String?
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
}

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// Log of the failed Wine operation, when there is one worth revealing.
    var logURL: URL?
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var bottles: [Bottle] = []
    @Published private(set) var programIconRevision = UUID()
    @Published private(set) var runtimes: [RuntimeDescriptor] = []
    @Published private(set) var settings = AppSettings()
    @Published private(set) var activities: [UUID: BottleActivity] = [:]
    @Published private(set) var isLoading = true
    @Published private(set) var runtimeActivity: String?
    @Published private(set) var installationProgress: WineInstallationProgress?
    @Published private(set) var runtimeError: String?
    @Published private(set) var isCreating = false
    @Published private(set) var creationError: String?
    @Published var selectedBottleID: UUID?
    @Published var showsNewBottle = false
    @Published var notice: AppNotice?

    let paths: ApplicationPaths
    private let store: BottleStore
    private let wine: WineRuntime
    private var hasStarted = false
    private var installationID: UUID?
    private var pendingOpenURLs: [URL] = []

    init(paths: ApplicationPaths = ApplicationPaths()) {
        self.paths = paths
        let store = BottleStore(paths: paths)
        self.store = store
        wine = WineRuntime(paths: paths, store: store)
    }

    var selectedBottle: Bottle? {
        bottles.first { $0.id == selectedBottleID }
    }

    var preferredRuntime: RuntimeDescriptor? {
        wine.preferredRuntime(in: runtimes, preferredPath: settings.preferredRuntimePath)
    }

    func activity(for bottle: Bottle) -> BottleActivity {
        activities[bottle.id] ?? BottleActivity()
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        GamepadService.shared.start()
        do {
            settings = try await store.settings()
        } catch {
            report(error, title: "Could Not Read Settings")
        }
        await loadBottles()
        await discoverRuntimes()
        isLoading = false
        drainOpenURLs()
    }

    func refreshBottles() {
        guard !isLoading else { return }
        // Do not replace metadata while an operation is saving the same bottle.
        guard !activities.values.contains(where: \.blocksLibraryEdit) else {
            notice = AppNotice(title: "A Bottle Is Busy", message: "Wait for bottle operations to finish before reloading the library. Other bottles are still available.")
            return
        }
        isLoading = true
        Task {
            await loadBottles()
            isLoading = false
            drainOpenURLs()
        }
    }

    private func drainOpenURLs() {
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        for url in urls { openInstallerURL(url) }
    }

    private func loadBottles() async {
        do {
            bottles = try await store.list()
            programIconRevision = UUID()
            if !bottles.contains(where: { $0.id == selectedBottleID }) {
                selectedBottleID = bottles.first?.id
            }
        } catch {
            report(error, title: "Could Not Load Bottles")
        }
    }

    private func discoverRuntimes() async {
        runtimeActivity = "Finding Wine…"
        var found = await wine.discover()
        if let path = settings.customWinePath {
            do {
                let custom = try await wine.inspect(executableURL: URL(fileURLWithPath: path))
                if !found.contains(where: { $0.id == custom.id }) { found.append(custom) }
            } catch {
                runtimeError = "The saved Wine executable could not be opened. \(error.localizedDescription)"
            }
        }
        runtimes = found
        if let preferred = preferredRuntime, preferred.executableURL.path != settings.preferredRuntimePath {
            do {
                var updated = settings
                updated.preferredRuntimePath = preferred.executableURL.path
                try await store.saveSettings(updated)
                settings = updated
            } catch {
                runtimeError = "Could not save the Wine preference. \(error.localizedDescription)"
            }
        }
        runtimeActivity = nil
    }

    func refreshRuntimes() {
        guard runtimeActivity == nil else { return }
        runtimeError = nil
        runtimeActivity = "Finding Wine…"
        Task { await discoverRuntimes() }
    }

    // Call only after the view's unsigned-runtime trust confirmation.
    func installWine(upgrading requestedBottle: Bottle? = nil) {
        guard !isLoading, runtimeActivity == nil else { return }
        let bottle: Bottle?
        if let requestedBottle {
            guard let current = bottles.first(where: { $0.id == requestedBottle.id }),
                  canUpgradeRuntime(current) else { return }
            var state = activity(for: current)
            guard !state.blocksPrefixMutation else { return }
            state.title = "Updating Wine…"
            state.error = nil
            activities[current.id] = state
            bottle = current
        } else {
            bottle = nil
        }
        let installationID = UUID()
        self.installationID = installationID
        updateInstallationProgress(.preparing)
        runtimeError = nil
        Task { [self] in
            defer {
                self.installationID = nil
                installationProgress = nil
                runtimeActivity = nil
                if let bottle {
                    var state = activity(for: bottle)
                    state.title = nil
                    activities[bottle.id] = state
                }
            }
            do {
                let installed = try await wine.installRuntime(acceptUnsigned: true) { [weak self] progress in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.installationID == installationID else { return }
                        self.updateInstallationProgress(progress)
                    }
                }
                addRuntime(installed)
                if let bottle {
                    runtimeActivity = "Switching bottle to updated Wine…"
                    let updated = try await wine.upgradeRuntime(in: bottle)
                    replace(updated)
                } else {
                    var updated = settings
                    updated.preferredRuntimePath = installed.executableURL.path
                    try await store.saveSettings(updated)
                    settings = updated
                }
            } catch {
                runtimeError = error.localizedDescription
            }
        }
    }

    private func updateInstallationProgress(_ progress: WineInstallationProgress) {
        installationProgress = progress
        switch progress {
        case .downloading:
            runtimeActivity = "Downloading Wine…"
        case .verifying:
            runtimeActivity = "Verifying Wine download…"
        case .extracting:
            runtimeActivity = "Extracting Wine…"
        case .preparing:
            runtimeActivity = "Preparing Wine…"
        case .reusing:
            runtimeActivity = "Using installed Wine…"
        case .checkingRuntime:
            runtimeActivity = "Checking Wine…"
        }
    }

    func chooseWineExecutable() {
        guard runtimeActivity == nil else { return }
        chooseFile(title: "Choose the Wine Executable", message: "Select the native wine or wineloader executable inside a Wine installation, not its application bundle or a wrapper that changes WINEPREFIX. Metal backends require a compatible Metal driver.", extensions: nil) { [weak self] url in
            self?.inspectCustomWine(url)
        }
    }

    private func inspectCustomWine(_ url: URL) {
        guard runtimeActivity == nil else { return }
        runtimeActivity = "Checking Wine…"
        runtimeError = nil
        Task {
            do {
                let runtime = try await wine.inspect(executableURL: url)
                addRuntime(runtime)
                var updated = settings
                updated.customWinePath = runtime.executableURL.path
                updated.preferredRuntimePath = runtime.executableURL.path
                try await store.saveSettings(updated)
                settings = updated
            } catch {
                runtimeError = error.localizedDescription
            }
            runtimeActivity = nil
        }
    }

    func preferRuntime(id: String) {
        guard runtimeActivity == nil, let runtime = runtimes.first(where: { $0.id == id }) else { return }
        runtimeActivity = "Saving Wine preference…"
        runtimeError = nil
        Task {
            do {
                var updated = settings
                updated.preferredRuntimePath = runtime.executableURL.path
                try await store.saveSettings(updated)
                settings = updated
            } catch {
                runtimeError = error.localizedDescription
            }
            runtimeActivity = nil
        }
    }

    private func addRuntime(_ runtime: RuntimeDescriptor) {
        runtimes.removeAll { $0.id == runtime.id }
        runtimes.append(runtime)
    }

    func createBottle(name: String, runtime: RuntimeDescriptor) {
        guard !isCreating else { return }
        isCreating = true
        creationError = nil
        Task {
            do {
                let bottle = try await store.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), runtime: runtime)
                bottles.append(bottle)
                selectedBottleID = bottle.id
                showsNewBottle = false
                initialize(bottle)
            } catch {
                creationError = error.localizedDescription
            }
            isCreating = false
        }
    }

    func initialize(_ bottle: Bottle) {
        perform(in: bottle, title: "Setting up Windows environment…", canStop: true) {
            let initialization = try await self.wine.initialize(bottle)
            self.replace(initialization.bottle)
            return initialization.result
        }
    }

    func chooseInstaller(in bottle: Bottle) {
        chooseFile(title: "Install a Windows Application", message: "Choose an EXE or MSI installer. Its Windows installer will open in this bottle.", extensions: ["exe", "msi"]) { [weak self] url in
            self?.install(url, in: bottle)
        }
    }

    func openInstallerURL(_ url: URL) {
        guard !isLoading else {
            pendingOpenURLs.append(url)
            return
        }
        guard url.isFileURL, ["exe", "msi"].contains(url.pathExtension.lowercased()) else {
            notice = AppNotice(title: "Unsupported File", message: "Open a Windows EXE or MSI installer. To register an existing program or shortcut, select a bottle and use Add Program.")
            return
        }
        guard let bottle = selectedBottle else {
            notice = AppNotice(title: "Choose a Bottle First", message: "Create or select a bottle, then open \(url.lastPathComponent) again or use Install EXE/MSI. Installers need a bottle to keep their Windows files and settings.")
            return
        }
        install(url, in: bottle)
    }

    private func install(_ url: URL, in bottle: Bottle) {
        let bottle = current(bottle)
        guard bottle.isInitialized else {
            notice = AppNotice(title: "Set Up This Bottle First", message: "Use Retry Setup for \(bottle.name), then open the installer again.")
            return
        }
        guard !activity(for: bottle).blocksPrefixMutation else {
            notice = AppNotice(title: "Bottle Is Busy", message: "Wait for the operation in \(bottle.name) to finish, or stop the bottle, before opening another installer.")
            return
        }
        perform(in: bottle, title: "Installing \(url.lastPathComponent)…", canStop: true) {
            let result = try await self.wine.install(url, in: bottle)
            self.recordLog(result.logURL, for: bottle.id)
            let updated = try await self.store.discoverPrograms(in: self.current(bottle))
            self.replace(updated)
            return result
        }
    }

    func chooseProgram(in bottle: Bottle) {
        chooseFile(title: "Add a Windows Program", message: "Choose an EXE, LNK shortcut, or URL Internet Shortcut. Removing it from MagicWine does not delete the file.", extensions: ["exe", "lnk", "url"]) { [weak self] url in
            guard let self else { return }
            self.perform(in: bottle, title: "Adding program…", allowsRunningPrograms: true) {
                let updated = try await self.store.registerProgram(in: self.current(bottle), executableURL: url)
                self.replace(updated)
                return nil
            }
        }
    }

    func refreshPrograms(in bottle: Bottle) {
        perform(in: bottle, title: "Finding Windows shortcuts…", allowsRunningPrograms: true) {
            let updated = try await self.store.discoverPrograms(in: self.current(bottle))
            self.replace(updated)
            return nil
        }
    }

    func removeProgram(_ program: WindowsProgram, in bottle: Bottle) {
        perform(in: bottle, title: "Removing shortcut…", allowsRunningPrograms: true) {
            let updated = try await self.store.removeProgram(id: program.id, in: self.current(bottle))
            self.replace(updated)
            return nil
        }
    }

    /// `diagnostics` is a one-off launch with a diagnostic `WINEDEBUG`; nothing is saved,
    /// and its log is offered when the program ends.
    func launch(_ program: WindowsProgram, in bottle: Bottle, diagnostics: Bool = false) {
        let bottle = current(bottle)
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
                    // Steam or a game can run for hours; warn as soon as it starts.
                    guard !start.warnings.isEmpty else { return }
                    Task { @MainActor in
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
            guard bottles.contains(where: { $0.id == bottle.id }) else { return }
            var latest = activity(for: bottle)
            latest.runningLaunches.remove(launchID)
            activities[bottle.id] = latest
        }
    }

    func dismissNotice(_ id: UUID, for bottle: Bottle) {
        guard var state = activities[bottle.id] else { return }
        state.notices.removeAll { $0.id == id }
        activities[bottle.id] = state
    }

    private func recordNotice(_ notice: BottleNotice, for id: UUID) {
        guard bottles.contains(where: { $0.id == id }) else { return }
        var state = activities[id] ?? BottleActivity()
        // Keep the dashboard compact when a launcher is reopened repeatedly.
        state.notices = Array((state.notices + [notice]).suffix(4))
        activities[id] = state
    }

    /// HUD is launch environment only: running programs keep going and those launched
    /// afterwards use the new setting. No exclusive operation title is shown.
    func setGraphicsHUD(_ showHUD: Bool, in bottle: Bottle) {
        guard !isLoading, let bottle = bottles.first(where: { $0.id == bottle.id }), bottle.isInitialized,
              bottle.graphics.backend != .standard, bottle.graphics.usesSupportedComponent,
              bottle.graphics.showHUD != showHUD else { return }
        var state = activity(for: bottle)
        guard state.title == nil, !state.isStopping, !state.isChangingHUD else { return }
        state.isChangingHUD = true
        state.error = nil
        activities[bottle.id] = state
        Task {
            do {
                replace(try await wine.setGraphicsHUD(showHUD, in: bottle))
            } catch {
                recordError(error, for: bottle.id)
            }
            guard bottles.contains(where: { $0.id == bottle.id }) else { return }
            var latest = activity(for: bottle)
            latest.isChangingHUD = false
            activities[bottle.id] = latest
        }
    }

    func configure(_ bottle: Bottle) {
        perform(in: bottle, title: "Wine configuration is open…", canStop: true) {
            try await self.wine.configure(bottle)
        }
    }

    func supportsMSync(_ bottle: Bottle) -> Bool { wine.supportsMSync(bottle.runtime) }

    func canUpgradeRuntime(_ bottle: Bottle) -> Bool { wine.canUpgradeRuntime(bottle.runtime) }

    func setMSyncEnabled(_ enabled: Bool, in bottle: Bottle) {
        guard !isLoading, let bottle = bottles.first(where: { $0.id == bottle.id }),
              supportsMSync(bottle) else { return }
        let state = activity(for: bottle)
        guard !state.blocksPrefixMutation, bottle.msyncEnabled != enabled else { return }
        perform(in: bottle, title: "Changing synchronization…") {
            let updated = try await self.wine.configureSynchronization(msyncEnabled: enabled, in: bottle)
            self.replace(updated)
            return nil
        }
    }

    func setRetinaEnabled(_ enabled: Bool, in bottle: Bottle) {
        guard !isLoading, let bottle = bottles.first(where: { $0.id == bottle.id }),
              bottle.isInitialized else { return }
        let state = activity(for: bottle)
        guard !state.blocksPrefixMutation else { return }
        let dpi: UInt32 = enabled ? 192 : 96
        guard bottle.display.retinaEnabled != enabled || bottle.display.dpi != dpi else { return }

        perform(in: bottle, title: "Changing display settings…") {
            let updated = try await self.wine.configureDisplay(retinaEnabled: enabled, in: bottle)
            self.replace(updated)
            return nil
        }
    }

    // The graphics view asks for consent before enabling third-party backends.
    func setGraphics(_ backend: GraphicsBackend, in bottle: Bottle, showHUD: Bool = false,
                     componentSource: URL? = nil) {
        guard !isLoading, let bottle = bottles.first(where: { $0.id == bottle.id }),
              bottle.isInitialized else { return }
        var state = activity(for: bottle)
        guard !state.blocksPrefixMutation else { return }
        let showHUD = backend != .standard && showHUD
        guard bottle.graphics.backend != backend || bottle.graphics.showHUD != showHUD || componentSource != nil else { return }

        let setupID = UUID()
        state.graphicsSetupID = setupID
        state.logURL = nil
        state.graphicsProgress = .stopping
        activities[bottle.id] = state
        perform(in: bottle, title: "Stopping Windows processes…") { [self] in
            let updated = try await self.wine.configureGraphics(
                backend, in: bottle, showHUD: showHUD, acceptExperimental: backend != .standard,
                componentSource: componentSource
            ) { [weak self] progress in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activities[bottle.id]?.graphicsSetupID == setupID else { return }
                    self.updateGraphicsProgress(progress, for: bottle.id)
                }
            }
            self.replace(updated)
            return nil
        }
    }

    private func updateGraphicsProgress(_ progress: GraphicsSetupProgress, for id: UUID) {
        guard var state = activities[id], state.graphicsSetupID != nil else { return }
        state.graphicsProgress = progress
        switch progress {
        case .stopping:
            state.title = "Stopping Windows processes…"
        case .verifying:
            state.title = "Verifying graphics component…"
        case .installing:
            state.title = "Installing graphics in this bottle…"
        case .restoring:
            state.title = "Restoring Standard graphics…"
        }
        activities[id] = state
    }

    func importD3DMetal(in bottle: Bottle) {
        guard !isLoading, let bottle = bottles.first(where: { $0.id == bottle.id }),
              bottle.isInitialized, !activity(for: bottle).blocksPrefixMutation else { return }
        if let source = WineRuntime.discoverD3DMetalSource(executable: bottle.runtime.executableURL) {
            setGraphics(.d3dmetal, in: bottle, showHUD: bottle.graphics.showHUD, componentSource: source)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import D3DMetal Libraries"
        panel.message = "No D3DMetal libraries were found beside this bottle’s Wine or in an installed CrossOver. Choose your legally obtained library folder. MagicWine does not download these libraries or accept their terms for you."
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.begin { [weak self] response in
            Task { @MainActor in
                if response == .OK, let url = panel.url {
                    self?.setGraphics(.d3dmetal, in: bottle, showHUD: bottle.graphics.showHUD, componentSource: url)
                }
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
                let result = try await wine.stop(bottle)
                recordLog(result.logURL, for: bottle.id)
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
            self.bottles.removeAll { $0.id == bottle.id }
            if self.selectedBottleID == bottle.id { self.selectedBottleID = self.bottles.first?.id }
            self.activities.removeValue(forKey: bottle.id)
            return nil
        }
    }

    func revealDrive(_ bottle: Bottle) {
        let drive = store.prefixURL(for: bottle).appendingPathComponent("drive_c", isDirectory: true)
        NSWorkspace.shared.activateFileViewerSelecting([drive])
    }

    func revealLogs(for bottle: Bottle? = nil) {
        if let bottle, let log = activity(for: bottle).logURL {
            NSWorkspace.shared.activateFileViewerSelecting([log])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([paths.logsDirectory])
        }
    }

    func revealLog(_ log: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }

    func dismissError(for bottle: Bottle) {
        var state = activity(for: bottle)
        state.error = nil
        activities[bottle.id] = state
    }

    private func perform(in bottle: Bottle, title: String, canStop: Bool = false,
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
            guard bottles.contains(where: { $0.id == bottle.id }) else { return }
            var latest = activity(for: bottle)
            latest.title = nil
            latest.canStop = false
            latest.graphicsProgress = nil
            latest.graphicsSetupID = nil
            activities[bottle.id] = latest
        }
    }

    private func current(_ bottle: Bottle) -> Bottle {
        bottles.first { $0.id == bottle.id } ?? bottle
    }

    private func replace(_ bottle: Bottle) {
        if let index = bottles.firstIndex(where: { $0.id == bottle.id }) {
            bottles[index] = bottle
            programIconRevision = UUID()
        }
    }

    private func recordLog(_ url: URL, for id: UUID) {
        var state = activities[id] ?? BottleActivity()
        state.logURL = url
        activities[id] = state
    }

    private func recordError(_ error: Error, for id: UUID) {
        var state = activities[id] ?? BottleActivity()
        if let wineError = error as? MagicWineError, case .stopped(let logURL) = wineError {
            state.logURL = logURL
            state.error = nil
        } else {
            state.error = error.localizedDescription
            if let wineError = error as? MagicWineError, case .processFailed(_, let logURL) = wineError {
                state.logURL = logURL
            }
        }
        activities[id] = state
    }

    private func report(_ error: Error, title: String) {
        var logURL: URL?
        switch error as? MagicWineError {
        case .processFailed(_, let url), .stopped(let url): logURL = url
        default: break
        }
        notice = AppNotice(title: title, message: error.localizedDescription, logURL: logURL)
    }

    private func chooseFile(title: String, message: String, extensions: [String]?,
                            selected: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if let extensions {
            panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        }
        panel.begin { response in
            Task { @MainActor in
                if response == .OK, let url = panel.url { selected(url) }
            }
        }
    }

    // MARK: - Program launch options

    /// Metadata only, like Add/Remove Program: allowed while programs run, and the next
    /// launch of this program uses the new options. Errors return to the editor sheet.
    func saveProgram(_ program: WindowsProgram, from original: WindowsProgram, in bottle: Bottle) async throws {
        guard !activity(for: bottle).blocksLibraryEdit else {
            throw MagicWineError.setup("Wait for this bottle’s operation to finish, then save again.")
        }
        replace(try await store.updateProgram(program, from: original, in: current(bottle)))
    }

    // MARK: - Compatibility switches

    @Published private(set) var changingCompatibility: Set<UUID> = []

    func rosettaAVXAvailability(_ bottle: Bottle) -> RosettaAVXAvailability {
        wine.rosettaAVXAvailability(bottle.runtime)
    }

    /// Launch switches only, like the HUD: running programs keep going and those launched
    /// afterwards use the new setting. No exclusive operation title is shown.
    func setCompatibility(_ options: CompatibilityOptions, in bottle: Bottle) {
        guard !isLoading, let bottle = bottles.first(where: { $0.id == bottle.id }),
              bottle.compatibility != options, !activity(for: bottle).blocksLibraryEdit,
              changingCompatibility.insert(bottle.id).inserted else { return }
        Task {
            do {
                replace(try await store.setCompatibility(options, in: bottle))
            } catch {
                recordError(error, for: bottle.id)
            }
            changingCompatibility.remove(bottle.id)
        }
    }

    // MARK: Storage cleanup

    @Published private(set) var storagePlan: StorageCleanupPlan?
    @Published private(set) var storageActivity: String?
    @Published private(set) var storageError: String?
    @Published private(set) var storageIncludesCurrent = false

    /// Bottle work and Wine installation can still reference what a plan lists. The core
    /// independently refuses while any bottle (including another process's) is busy.
    var blocksStorageCleanup: Bool {
        isLoading || isCreating || runtimeActivity != nil || storageActivity != nil ||
            activities.values.contains { $0.blocksPrefixMutation }
    }

    func refreshStoragePlan(includeCurrent: Bool? = nil) {
        guard storageActivity == nil else { return }
        if let includeCurrent { storageIncludesCurrent = includeCurrent }
        storageActivity = "Measuring unused files…"
        storageError = nil
        Task {
            await loadStoragePlan()
            storageActivity = nil
        }
    }

    /// Call only after the view's confirmation listing exactly these items.
    func removeStorage(_ items: [StorageCleanupItem]) {
        guard !blocksStorageCleanup, !items.isEmpty else { return }
        storageActivity = "Removing unused files…"
        // Keeps Wine installation and bottle creation from racing the removal.
        runtimeActivity = "Removing unused files…"
        storageError = nil
        let paths = paths
        Task {
            var removedRuntime = false
            do {
                let result = try await StorageCleanup.apply(items, paths: paths)
                removedRuntime = result.removed.contains { $0.category == .runtime }
                let size = ByteCountFormatter.string(fromByteCount: result.reclaimedSize, countStyle: .file)
                notice = AppNotice(title: "Unused Files Removed", message: "Removed \(result.removed.count) of \(items.count) items (\(size))."
                    + (result.skipped.isEmpty ? "" : " \(result.skipped.count) items were kept because they are in use again or already gone."))
            } catch {
                storageError = error.localizedDescription
            }
            runtimeActivity = nil
            if removedRuntime { await discoverRuntimes() }
            await loadStoragePlan()
            storageActivity = nil
        }
    }

    private func loadStoragePlan() async {
        do {
            storagePlan = try await StorageCleanup.plan(paths: paths, includeCurrent: storageIncludesCurrent)
        } catch {
            storagePlan = nil
            if storageError == nil { storageError = error.localizedDescription }
        }
    }

    // MARK: Graphics component updates

    /// The graphics view asks for consent first. Switches a bottle from its retained older
    /// component to the current bundled one in one journaled prefix transaction.
    func updateGraphicsComponent(in bottle: Bottle) {
        guard !isLoading, let bottle = bottles.first(where: { $0.id == bottle.id }),
              bottle.isInitialized, bottle.graphics.hasComponentUpdate else { return }
        var state = activity(for: bottle)
        guard !state.blocksPrefixMutation else { return }
        let setupID = UUID()
        state.graphicsSetupID = setupID
        state.logURL = nil
        state.graphicsProgress = .stopping
        activities[bottle.id] = state
        perform(in: bottle, title: "Stopping Windows processes…") { [self] in
            let updated = try await self.wine.updateGraphicsComponent(in: bottle, acceptExperimental: true) { [weak self] progress in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activities[bottle.id]?.graphicsSetupID == setupID else { return }
                    self.updateGraphicsProgress(progress, for: bottle.id)
                }
            }
            self.replace(updated)
            return nil
        }
    }
}

/// A dismissible, non-error status for one bottle, tied to one specific process log.
struct BottleNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let logURL: URL
}
