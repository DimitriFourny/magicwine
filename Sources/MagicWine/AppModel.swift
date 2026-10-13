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
}

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var bottles: [Bottle] = []
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
        store = BottleStore(paths: paths)
        wine = WineRuntime(paths: paths)
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
        guard !activities.values.contains(where: { $0.title != nil }) else {
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

    func installWine() {
        guard runtimeActivity == nil else { return }
        let installationID = UUID()
        self.installationID = installationID
        updateInstallationProgress(.preparing)
        runtimeError = nil
        Task { [self] in
            defer {
                self.installationID = nil
                installationProgress = nil
                runtimeActivity = nil
            }
            do {
                let installed = try await wine.installRuntime(acceptUnsigned: true) { [weak self] progress in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.installationID == installationID else { return }
                        self.updateInstallationProgress(progress)
                    }
                }
                addRuntime(installed)
                var updated = settings
                updated.preferredRuntimePath = installed.executableURL.path
                try await store.saveSettings(updated)
                settings = updated
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
            let result = try await self.wine.initialize(bottle)
            var updated = self.current(bottle)
            updated.isInitialized = true
            try await self.store.save(updated)
            self.replace(updated)
            return result
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
        guard activity(for: bottle).title == nil else {
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
        chooseFile(title: "Add a Windows Program", message: "Choose an EXE or LNK shortcut. Removing it from MagicWine does not delete the file.", extensions: ["exe", "lnk"]) { [weak self] url in
            guard let self else { return }
            self.perform(in: bottle, title: "Adding program…") {
                let updated = try await self.store.registerProgram(in: self.current(bottle), executableURL: url)
                self.replace(updated)
                return nil
            }
        }
    }

    func refreshPrograms(in bottle: Bottle) {
        perform(in: bottle, title: "Finding Windows shortcuts…") {
            let updated = try await self.store.discoverPrograms(in: self.current(bottle))
            self.replace(updated)
            return nil
        }
    }

    func removeProgram(_ program: WindowsProgram, in bottle: Bottle) {
        perform(in: bottle, title: "Removing shortcut…") {
            let updated = try await self.store.removeProgram(id: program.id, in: self.current(bottle))
            self.replace(updated)
            return nil
        }
    }

    func launch(_ program: WindowsProgram, in bottle: Bottle) {
        perform(in: bottle, title: "Running \(program.name)…", canStop: true) {
            try await self.wine.launch(program, in: bottle)
        }
    }

    func configure(_ bottle: Bottle) {
        perform(in: bottle, title: "Wine configuration is open…", canStop: true) {
            try await self.wine.configure(bottle)
        }
    }

    // The graphics view asks for consent before enabling third-party backends.
    func setGraphics(_ backend: GraphicsBackend, in bottle: Bottle, showHUD: Bool = false,
                     componentSource: URL? = nil) {
        guard !isLoading, let bottle = bottles.first(where: { $0.id == bottle.id }),
              bottle.isInitialized else { return }
        var state = activity(for: bottle)
        guard state.title == nil, !state.isStopping else { return }
        let showHUD = backend != .standard && showHUD
        guard bottle.graphics.backend != backend || bottle.graphics.showHUD != showHUD || componentSource != nil else { return }

        let setupID = UUID()
        state.graphicsSetupID = setupID
        state.logURL = nil
        state.graphicsProgress = .stopping
        activities[bottle.id] = state
        perform(in: bottle, title: "Stopping Windows processes…") { [self] in
            do {
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
            } catch {
                self.report(error, title: "Could Not Change Graphics")
                throw error
            }
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
              bottle.isInitialized, activity(for: bottle).title == nil,
              !activity(for: bottle).isStopping else { return }
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

    func dismissError(for bottle: Bottle) {
        var state = activity(for: bottle)
        state.error = nil
        activities[bottle.id] = state
    }

    private func perform(in bottle: Bottle, title: String, canStop: Bool = false,
                         operation: @escaping @MainActor () async throws -> OperationResult?) {
        var state = activity(for: bottle)
        guard state.title == nil, !state.isStopping else { return }
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
        if let index = bottles.firstIndex(where: { $0.id == bottle.id }) { bottles[index] = bottle }
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
        notice = AppNotice(title: title, message: error.localizedDescription)
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
}
