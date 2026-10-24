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
/// (startup, reload, file opening, bottle creation).
@Observable
@MainActor
final class AppModel {
    let paths: ApplicationPaths
    let notices: NoticeModel
    /// Bottles, selection, creation, and icon revisions.
    let library: LibraryModel
    /// Wine runtimes and app settings.
    let runtimes: RuntimeModel
    /// Per-bottle operations, running launches, live logs.
    let activity: BottleActivityModel
    /// Graphics, display, synchronization, HUD, compatibility, and program options.
    let bottleSettings: BottleSettingsModel
    let storage: StorageCleanupModel
    let dependencies: DependenciesModel

    var showsNewBottle = false

    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var pendingOpenURLs: [URL] = []

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
        storage = StorageCleanupModel(paths: paths, library: library, runtimes: runtimes, activity: activity, notices: notices)
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
        drainOpenURLs()
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
            drainOpenURLs()
        }
    }

    private func drainOpenURLs() {
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        for url in urls { openInstallerURL(url) }
    }

    func openInstallerURL(_ url: URL) {
        guard !library.isLoading else {
            pendingOpenURLs.append(url)
            return
        }
        guard url.isFileURL, ["exe", "msi"].contains(url.pathExtension.lowercased()) else {
            notices.post(AppNotice(title: "Unsupported File", message: "Open a Windows EXE or MSI installer. To register an existing program or shortcut, select a bottle and use Add Program."))
            return
        }
        guard let bottle = library.selectedBottle else {
            notices.post(AppNotice(title: "Choose a Bottle First", message: "Create or select a bottle, then open \(url.lastPathComponent) again or use Install EXE/MSI. Installers need a bottle to keep their Windows files and settings."))
            return
        }
        activity.install(url, in: bottle)
    }

    func createBottle(name: String, runtime: RuntimeDescriptor) {
        Task {
            guard let bottle = await library.create(name: name, runtime: runtime) else { return }
            showsNewBottle = false
            activity.initialize(bottle)
        }
    }
}
