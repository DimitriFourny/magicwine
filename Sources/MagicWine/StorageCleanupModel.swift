import Foundation
import MagicWineCore
import Observation

/// The unused-storage plan shown in Downloads › Storage, and its confirmed removal.
@Observable
@MainActor
final class StorageCleanupModel {
    private(set) var plan: StorageCleanupPlan?
    private(set) var activity: String?
    private(set) var error: String?
    private(set) var includesCurrent = false

    @ObservationIgnored private let store: BottleStore
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let runtimes: RuntimeModel
    @ObservationIgnored private let bottleActivity: BottleActivityModel
    @ObservationIgnored private let notices: NoticeModel

    init(store: BottleStore, library: LibraryModel, runtimes: RuntimeModel, activity: BottleActivityModel,
         notices: NoticeModel) {
        self.store = store
        self.library = library
        self.runtimes = runtimes
        bottleActivity = activity
        self.notices = notices
    }

    /// Bottle work and Wine installation can still reference what a plan lists. The core
    /// independently refuses while any bottle (including another process's) is busy.
    var blocksCleanup: Bool {
        library.isLoading || library.isCreating || runtimes.activity != nil || activity != nil ||
            bottleActivity.activities.values.contains { $0.blocksPrefixMutation }
    }

    func refresh(includeCurrent: Bool? = nil) {
        guard activity == nil else { return }
        if let includeCurrent { includesCurrent = includeCurrent }
        activity = localized("Measuring unused files…")
        error = nil
        Task {
            await loadPlan()
            activity = nil
        }
    }

    /// Call only after the view's confirmation listing exactly these items.
    func remove(_ items: [StorageCleanupItem]) {
        guard !blocksCleanup, !items.isEmpty else { return }
        activity = localized("Removing unused files…")
        // Keeps Wine installation and bottle creation from racing the removal.
        runtimes.reserve(localized("Removing unused files…"))
        error = nil
        Task {
            var removedRuntime = false
            do {
                let result = try await StorageCleanup.apply(items, store: store)
                removedRuntime = result.removed.contains { $0.category == .runtime }
                let size = ByteCountFormatter.string(fromByteCount: result.reclaimedSize, countStyle: .file)
                let removed = localized("Removed \(result.removed.count) of \(items.count) items (\(size)).")
                let kept = result.skipped.isEmpty ? "" : " " + localized("\(result.skipped.count) items were kept because they are in use again or already gone.")
                notices.post(AppNotice(title: localized("Unused Files Removed"), message: removed + kept))
            } catch {
                self.error = error.localizedDescription
            }
            runtimes.release()
            if removedRuntime { await runtimes.discover() }
            await loadPlan()
            activity = nil
        }
    }

    private func loadPlan() async {
        do {
            plan = try await StorageCleanup.plan(store: store, includeCurrent: includesCurrent)
        } catch {
            plan = nil
            if self.error == nil { self.error = error.localizedDescription }
        }
    }
}
