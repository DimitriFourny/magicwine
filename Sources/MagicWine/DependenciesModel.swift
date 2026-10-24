import Foundation
import MagicWineCore
import Observation

/// Windows dependency status and installation per bottle.
@Observable
@MainActor
final class DependenciesModel {
    private(set) var statuses: [UUID: [DependencyStatus]] = [:]
    private(set) var progress: [UUID: DependencyProgress] = [:]
    private(set) var errors: [UUID: String] = [:]

    @ObservationIgnored private let wine: WineRuntime
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let activity: BottleActivityModel

    init(wine: WineRuntime, library: LibraryModel, activity: BottleActivityModel) {
        self.wine = wine
        self.library = library
        self.activity = activity
    }

    /// Reads the post-install checks; Wine does not need to run.
    func refresh(in bottle: Bottle) {
        let bottle = library.current(bottle)
        guard bottle.isInitialized else { return }
        Task {
            do {
                statuses[bottle.id] = try await wine.dependencyStatus(in: bottle)
            } catch {
                errors[bottle.id] = error.localizedDescription
            }
        }
    }

    /// Call only after the view's license confirmation for exactly these items.
    func install(_ ids: [String], in bottle: Bottle) {
        let bottle = library.current(bottle)
        guard !library.isLoading, bottle.isInitialized, !ids.isEmpty,
              !activity.activity(for: bottle).blocksPrefixMutation else { return }
        errors[bottle.id] = nil
        activity.perform(in: bottle, title: "Preparing Windows dependencies…", canStop: true) { [self] in
            defer {
                progress[bottle.id] = nil
                refresh(in: bottle)
            }
            do {
                let result = try await wine.installDependencies(ids, in: bottle, acceptLicense: true) { [weak self] progress in
                    DispatchQueue.main.async { [weak self] in
                        self?.update(progress, for: bottle.id)
                    }
                }
                library.replace(result.bottle)
                return OperationResult(exitCode: 0, logURL: result.logURL)
            } catch {
                if case .stopped? = error as? MagicWineError {} else {
                    errors[bottle.id] = error.localizedDescription
                }
                throw error
            }
        }
    }

    private func update(_ progress: DependencyProgress, for id: UUID) {
        guard activity.activities[id]?.title != nil else { return }
        func name(_ item: String) -> String { DependencyCatalog.item(id: item)?.name ?? item }
        activity.update(id, ifPresent: true) { state in
            switch progress {
            case .started(let log): state.logURL = log
            case .downloading(let item, _): state.title = "Downloading \(name(item))…"
            case .verifying(let item): state.title = "Verifying \(name(item))…"
            case .installing(let item): state.title = "Installing \(name(item))…"
            case .checking(let item): state.title = "Checking \(name(item))…"
            }
        }
        self.progress[id] = progress
    }
}
