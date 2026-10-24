import Foundation
import MagicWineCore
import Observation

struct AppNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    /// Log of the failed Wine operation, when there is one worth revealing.
    var logURL: URL?
}

/// The app-wide alert, one at a time, presented by the main window.
@Observable
@MainActor
final class NoticeModel {
    var current: AppNotice?

    func post(_ notice: AppNotice) {
        current = notice
    }

    func report(_ error: Error, title: String) {
        current = AppNotice(title: title, error: error)
    }
}

/// Composition root: creates the library's single `BottleStore` and `WineRuntime` and the
/// focused models that share them, and runs the flows that span several of them
/// (startup, reload, file opening, bottle creation). Selection, sheets, and files opened
/// before the library loaded belong to each window, not to these shared models.
@Observable
@MainActor
final class AppModel {
    let paths: ApplicationPaths
    let notices: NoticeModel
    /// Bottles, creation, and icon revisions.
    let library: LibraryModel
    /// Wine runtimes and app settings.
    let runtimes: RuntimeModel
    /// Per-bottle operations, running launches, live logs.
    let activity: BottleActivityModel
    /// Graphics, display, synchronization, HUD, compatibility, and program options.
    let bottleSettings: BottleSettingsModel
    let storage: StorageCleanupModel
    let dependencies: DependenciesModel

    @ObservationIgnored private var hasStarted = false

    init(paths: ApplicationPaths = ApplicationPaths()) {
        self.paths = paths
        let store = BottleStore(paths: paths)
        let wine = WineRuntime(paths: paths, store: store)
        let notices = NoticeModel()
        let library = LibraryModel(paths: paths, store: store, notices: notices)
        let activity = BottleActivityModel(wine: wine, store: store, library: library, notices: notices)
        let runtimes = RuntimeModel(wine: wine, store: store, library: library, activity: activity, notices: notices)
        self.notices = notices
        self.library = library
        self.activity = activity
        self.runtimes = runtimes
        bottleSettings = BottleSettingsModel(wine: wine, store: store, library: library, activity: activity, runtimes: runtimes)
        storage = StorageCleanupModel(store: store, library: library, runtimes: runtimes, activity: activity, notices: notices)
        dependencies = DependenciesModel(wine: wine, library: library, activity: activity)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        GamepadService.shared.start()
        let paths = paths
        Task.detached(priority: .utility) { ProcessLogs.prune(paths: paths) }
        await runtimes.loadSettings()
        await library.load()
        await runtimes.discover()
        library.isLoading = false
    }

    func refreshBottles() {
        guard !library.isLoading else { return }
        // Do not replace metadata while an operation is saving the same bottle.
        guard !activity.activities.values.contains(where: \.blocksLibraryEdit) else {
            notices.post(AppNotice(title: "A Bottle Is Busy", message: "Wait for bottle operations to finish before reloading the library. Other bottles are still available."))
            return
        }
        library.isLoading = true
        Task {
            await library.load()
            library.isLoading = false
        }
    }

    /// A file opened from Finder or the Dock. `nil`, with a notice, when it is not a Windows
    /// EXE, MSI, LNK, or URL file. The window asks which bottle and action to use.
    func openedFile(_ url: URL, preferringProgram: Bool) -> OpenedFile? {
        if let file = OpenedFile(url: url, preferringProgram: preferringProgram) { return file }
        notices.post(AppNotice(title: "Unsupported File", message: "Open a Windows EXE or MSI installer, or an EXE, LNK, or URL shortcut to add as a program."))
        return nil
    }

    /// Runs `action` for `file` in `bottle`: an installer, or a registered program.
    func open(_ file: OpenedFile, as action: OpenedFileAction, in bottle: Bottle) {
        switch action {
        case .install: activity.install(file.url, in: bottle)
        case .addProgram: activity.addPrograms([file.url], to: bottle)
        }
    }

    /// Files dropped on a bottle's row or dashboard: one EXE/MSI installer, run like Install EXE/MSI.
    func install(dropped urls: [URL], in bottle: Bottle) {
        let installers = urls.filter { OpenedFile.installerExtensions.contains($0.pathExtension.lowercased()) }
        guard installers.count == 1, let installer = installers.first else {
            notices.post(AppNotice(
                title: installers.isEmpty ? "Unsupported File" : "One Installer at a Time",
                message: installers.isEmpty
                    ? "Drop a Windows EXE or MSI installer here to install it in \(bottle.name). To add an existing program, drop it on the Installed Programs list."
                    : "Drop one installer at a time, and wait for it to finish."))
            return
        }
        activity.install(installer, in: bottle)
    }

    /// Files dropped on a bottle's program list: EXE, LNK, and URL files, registered like Add Program.
    func addPrograms(dropped urls: [URL], to bottle: Bottle) {
        let programs = urls.filter { OpenedFile.programExtensions.contains($0.pathExtension.lowercased()) }
        guard !programs.isEmpty else {
            notices.post(AppNotice(title: "Unsupported File", message: "Drop an EXE, LNK shortcut, or URL Internet Shortcut here to add it to \(bottle.name). To run an installer, drop an EXE or MSI on the bottle instead."))
            return
        }
        activity.addPrograms(programs, to: bottle)
    }

    /// Creates a bottle and starts its setup; `nil` when creation failed or another runs.
    /// `pending` runs once setup has finished, for a file the user opened before choosing
    /// to create a new bottle.
    func createBottle(name: String, runtime: RuntimeDescriptor, then pending: PendingOpen? = nil) async -> Bottle? {
        guard let bottle = await library.create(name: name, runtime: runtime) else { return nil }
        activity.initialize(bottle) { [self] succeeded in
            guard let pending else { return }
            guard succeeded, let ready = library.bottles.first(where: { $0.id == bottle.id }) else {
                notices.post(AppNotice(title: "File Not Opened", message: "\(bottle.name) could not be set up, so \(pending.file.url.lastPathComponent) was not opened. Retry setup in the bottle, then open the file again."))
                return
            }
            open(pending.file, as: pending.action, in: ready)
        }
        return bottle
    }
}
