import Foundation
import MagicWineCore
import Observation

/// The loaded bottles, the selection, bottle creation, and per-bottle icon revisions.
/// Other models change a bottle only by handing the core's saved result to `replace`.
@Observable
@MainActor
final class LibraryModel {
    private(set) var bottles: [Bottle] = []
    /// Set by `AppModel`'s startup and reload sequence; operations wait while it is set.
    var isLoading = true
    var selectedBottleID: UUID?
    private(set) var isCreating = false
    private(set) var creationError: String?
    /// Bumped per bottle whenever its saved record is replaced or reloaded, so only that
    /// bottle's program icons are checked again.
    private(set) var iconRevisions: [UUID: Int] = [:]

    let paths: ApplicationPaths
    @ObservationIgnored private let store: BottleStore
    @ObservationIgnored private let notices: NoticeModel

    init(paths: ApplicationPaths, store: BottleStore, notices: NoticeModel) {
        self.paths = paths
        self.store = store
        self.notices = notices
    }

    var selectedBottle: Bottle? {
        bottles.first { $0.id == selectedBottleID }
    }

    func contains(_ id: UUID) -> Bool {
        bottles.contains { $0.id == id }
    }

    /// The latest loaded record of `bottle`, or `bottle` itself once it is gone.
    func current(_ bottle: Bottle) -> Bottle {
        bottles.first { $0.id == bottle.id } ?? bottle
    }

    func iconRevision(for id: UUID) -> Int {
        iconRevisions[id] ?? 0
    }

    func bottleURL(for bottle: Bottle) -> URL {
        paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
    }

    func driveURL(for bottle: Bottle) -> URL {
        store.prefixURL(for: bottle).appendingPathComponent("drive_c", isDirectory: true)
    }

    func load() async {
        do {
            bottles = try await store.list()
            for bottle in bottles { iconRevisions[bottle.id, default: 0] += 1 }
            if !bottles.contains(where: { $0.id == selectedBottleID }) {
                selectedBottleID = bottles.first?.id
            }
        } catch {
            notices.report(error, title: "Could Not Load Bottles")
        }
    }

    /// Creates and selects a new bottle; `nil` while another creation runs or on failure
    /// (shown as `creationError`).
    func create(name: String, runtime: RuntimeDescriptor) async -> Bottle? {
        guard !isCreating else { return nil }
        isCreating = true
        creationError = nil
        defer { isCreating = false }
        do {
            let bottle = try await store.create(name: name.trimmingCharacters(in: .whitespacesAndNewlines), runtime: runtime)
            bottles.append(bottle)
            selectedBottleID = bottle.id
            return bottle
        } catch {
            creationError = error.localizedDescription
            return nil
        }
    }

    func replace(_ bottle: Bottle) {
        if let index = bottles.firstIndex(where: { $0.id == bottle.id }) {
            bottles[index] = bottle
            iconRevisions[bottle.id, default: 0] += 1
        }
    }

    func remove(_ id: UUID) {
        bottles.removeAll { $0.id == id }
        iconRevisions[id] = nil
        if selectedBottleID == id { selectedBottleID = bottles.first?.id }
    }
}
