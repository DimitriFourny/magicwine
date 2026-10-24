import Foundation
import MagicWineCore
import Observation

/// Installed and custom Wine runtimes, the preferred runtime, and Wine installation.
@Observable
@MainActor
final class RuntimeModel {
    private(set) var runtimes: [RuntimeDescriptor] = []
    private(set) var settings = AppSettings()
    /// Discovery, installation, inspection, or a storage removal that must not race them.
    private(set) var activity: String?
    private(set) var installationProgress: WineInstallationProgress?
    private(set) var error: String?

    @ObservationIgnored private var installationID: UUID?
    @ObservationIgnored private let wine: WineRuntime
    @ObservationIgnored private let store: BottleStore
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let bottleActivity: BottleActivityModel
    @ObservationIgnored private let notices: NoticeModel

    init(wine: WineRuntime, store: BottleStore, library: LibraryModel, activity: BottleActivityModel,
         notices: NoticeModel) {
        self.wine = wine
        self.store = store
        self.library = library
        bottleActivity = activity
        self.notices = notices
    }

    var preferredRuntime: RuntimeDescriptor? {
        wine.preferredRuntime(in: runtimes, preferredPath: settings.preferredRuntimePath)
    }

    func supportsMSync(_ bottle: Bottle) -> Bool { wine.supportsMSync(bottle.runtime) }

    func canUpgradeRuntime(_ bottle: Bottle) -> Bool { wine.canUpgradeRuntime(bottle.runtime) }

    func loadSettings() async {
        do {
            settings = try await store.settings()
        } catch {
            notices.report(error, title: localized("Could Not Read Settings"))
        }
    }

    func discover() async {
        activity = localized("Finding Wine…")
        var found = await wine.discover()
        if let path = settings.customWinePath {
            do {
                // Inspected again only when the saved executable changed since it last ran.
                let custom = try await wine.inspect(executableURL: URL(fileURLWithPath: path), reusingCachedResult: true)
                if !found.contains(where: { $0.id == custom.id }) { found.append(custom) }
            } catch {
                self.error = localized("The saved Wine executable could not be opened. \(error.localizedDescription)")
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
                self.error = localized("Could not save the Wine preference. \(error.localizedDescription)")
            }
        }
        activity = nil
    }

    func refresh() {
        guard activity == nil else { return }
        error = nil
        activity = localized("Finding Wine…")
        Task { await discover() }
    }

    /// Storage cleanup holds this so Wine installation and bottle creation cannot race
    /// its removal. Call only while `activity` is `nil`.
    func reserve(_ title: String) {
        activity = title
    }

    func release() {
        activity = nil
    }

    // Call only after the view's unsigned-runtime trust confirmation.
    func installWine(upgrading requestedBottle: Bottle? = nil) {
        guard !library.isLoading, activity == nil else { return }
        let bottle: Bottle?
        if let requestedBottle {
            guard let current = library.bottles.first(where: { $0.id == requestedBottle.id }),
                  canUpgradeRuntime(current) else { return }
            guard !bottleActivity.activity(for: current).blocksPrefixMutation else { return }
            bottleActivity.update(current.id) { state in
                state.title = localized("Updating Wine…")
                state.error = nil
            }
            bottle = current
        } else {
            bottle = nil
        }
        let installationID = UUID()
        self.installationID = installationID
        updateInstallationProgress(.preparing)
        error = nil
        Task { [self] in
            defer {
                self.installationID = nil
                installationProgress = nil
                activity = nil
                if let bottle {
                    bottleActivity.update(bottle.id) { $0.title = nil }
                }
            }
            do {
                let installed = try await wine.installRuntime(acceptUnsigned: true) { [weak self] progress in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.installationID == installationID else { return }
                        self.updateInstallationProgress(progress)
                    }
                }
                add(installed)
                if let bottle {
                    activity = localized("Switching bottle to updated Wine…")
                    let updated = try await wine.upgradeRuntime(in: bottle)
                    library.replace(updated)
                } else {
                    var updated = settings
                    updated.preferredRuntimePath = installed.executableURL.path
                    try await store.saveSettings(updated)
                    settings = updated
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func updateInstallationProgress(_ progress: WineInstallationProgress) {
        installationProgress = progress
        switch progress {
        case .downloading:
            activity = localized("Downloading Wine…")
        case .verifying:
            activity = localized("Verifying Wine download…")
        case .extracting:
            activity = localized("Extracting Wine…")
        case .preparing:
            activity = localized("Preparing Wine…")
        case .reusing:
            activity = localized("Using installed Wine…")
        case .checkingRuntime:
            activity = localized("Checking Wine…")
        }
    }

    /// Inspects the executable the user chose; on success it becomes the custom and preferred Wine.
    func inspectCustomWine(_ url: URL) {
        guard activity == nil else { return }
        activity = localized("Checking Wine…")
        error = nil
        Task {
            do {
                let runtime = try await wine.inspect(executableURL: url)
                add(runtime)
                var updated = settings
                updated.customWinePath = runtime.executableURL.path
                updated.preferredRuntimePath = runtime.executableURL.path
                try await store.saveSettings(updated)
                settings = updated
            } catch {
                self.error = error.localizedDescription
            }
            activity = nil
        }
    }

    func prefer(id: String) {
        guard activity == nil, let runtime = runtimes.first(where: { $0.id == id }) else { return }
        activity = localized("Saving Wine preference…")
        error = nil
        Task {
            do {
                var updated = settings
                updated.preferredRuntimePath = runtime.executableURL.path
                try await store.saveSettings(updated)
                settings = updated
            } catch {
                self.error = error.localizedDescription
            }
            activity = nil
        }
    }

    private func add(_ runtime: RuntimeDescriptor) {
        runtimes.removeAll { $0.id == runtime.id }
        runtimes.append(runtime)
    }
}
