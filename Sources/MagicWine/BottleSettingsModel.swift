import Foundation
import MagicWineCore
import Observation

/// A bottle's settings: graphics backend and component, display, synchronization, HUD,
/// compatibility switches, and per-program launch options. Prefix changes run as
/// exclusive `BottleActivityModel` operations; launch-only settings do not.
@Observable
@MainActor
final class BottleSettingsModel {
    private(set) var changingCompatibility: Set<UUID> = []

    @ObservationIgnored private let wine: WineRuntime
    @ObservationIgnored private let store: BottleStore
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let activity: BottleActivityModel
    @ObservationIgnored private let runtimes: RuntimeModel

    init(wine: WineRuntime, store: BottleStore, library: LibraryModel, activity: BottleActivityModel,
         runtimes: RuntimeModel) {
        self.wine = wine
        self.store = store
        self.library = library
        self.activity = activity
        self.runtimes = runtimes
    }

    // MARK: - Graphics

    // The graphics view asks for consent before enabling third-party backends.
    func setGraphics(_ backend: GraphicsBackend, in bottle: Bottle, showHUD: Bool = false,
                     componentSource: URL? = nil) {
        guard !library.isLoading, let bottle = library.bottles.first(where: { $0.id == bottle.id }),
              bottle.isInitialized else { return }
        guard !activity.activity(for: bottle).blocksPrefixMutation else { return }
        let showHUD = backend != .standard && showHUD
        guard bottle.graphics.backend != backend || bottle.graphics.showHUD != showHUD || componentSource != nil else { return }

        let setupID = beginGraphicsSetup(for: bottle.id)
        activity.perform(in: bottle, title: "Stopping Windows processes…") { [self] in
            let updated = try await wine.configureGraphics(
                backend, in: bottle, showHUD: showHUD, acceptExperimental: backend != .standard,
                componentSource: componentSource
            ) { [weak self] progress in
                DispatchQueue.main.async { [weak self] in
                    self?.updateGraphicsProgress(progress, for: bottle.id, setupID: setupID)
                }
            }
            library.replace(updated)
            return nil
        }
    }

    /// Uses D3DMetal libraries found beside the bottle's Wine or in an installed CrossOver;
    /// when there are none, `chooseFolder` asks the user for the library folder.
    func importD3DMetal(in bottle: Bottle, chooseFolder: (Bottle) -> Void) {
        guard !library.isLoading, let bottle = library.bottles.first(where: { $0.id == bottle.id }),
              bottle.isInitialized, !activity.activity(for: bottle).blocksPrefixMutation else { return }
        if let source = WineRuntime.discoverD3DMetalSource(executable: bottle.runtime.executableURL) {
            setGraphics(.d3dmetal, in: bottle, showHUD: bottle.graphics.showHUD, componentSource: source)
            return
        }
        chooseFolder(bottle)
    }

    /// The graphics view asks for consent first. Switches a bottle from its retained older
    /// component to the current bundled one in one journaled prefix transaction.
    func updateGraphicsComponent(in bottle: Bottle) {
        guard !library.isLoading, let bottle = library.bottles.first(where: { $0.id == bottle.id }),
              bottle.isInitialized, bottle.graphics.hasComponentUpdate else { return }
        guard !activity.activity(for: bottle).blocksPrefixMutation else { return }
        let setupID = beginGraphicsSetup(for: bottle.id)
        activity.perform(in: bottle, title: "Stopping Windows processes…") { [self] in
            let updated = try await wine.updateGraphicsComponent(in: bottle, acceptExperimental: true) { [weak self] progress in
                DispatchQueue.main.async { [weak self] in
                    self?.updateGraphicsProgress(progress, for: bottle.id, setupID: setupID)
                }
            }
            library.replace(updated)
            return nil
        }
    }

    private func beginGraphicsSetup(for id: UUID) -> UUID {
        let setupID = UUID()
        activity.update(id) { state in
            state.graphicsSetupID = setupID
            state.logURL = nil
            state.graphicsProgress = .stopping
        }
        return setupID
    }

    /// A late callback from an earlier setup must not update a newer one.
    private func updateGraphicsProgress(_ progress: GraphicsSetupProgress, for id: UUID, setupID: UUID) {
        guard activity.activities[id]?.graphicsSetupID == setupID else { return }
        activity.update(id, ifPresent: true) { state in
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
        }
    }

    /// HUD is launch environment only: running programs keep going and those launched
    /// afterwards use the new setting. No exclusive operation title is shown.
    func setGraphicsHUD(_ showHUD: Bool, in bottle: Bottle) {
        guard !library.isLoading, let bottle = library.bottles.first(where: { $0.id == bottle.id }), bottle.isInitialized,
              bottle.graphics.backend != .standard, bottle.graphics.usesSupportedComponent,
              bottle.graphics.showHUD != showHUD else { return }
        let state = activity.activity(for: bottle)
        guard state.title == nil, !state.isStopping, !state.isChangingHUD else { return }
        activity.update(bottle.id) { state in
            state.isChangingHUD = true
            state.error = nil
        }
        Task {
            do {
                library.replace(try await wine.setGraphicsHUD(showHUD, in: bottle))
            } catch {
                activity.recordError(error, for: bottle.id)
            }
            guard library.contains(bottle.id) else { return }
            activity.update(bottle.id) { $0.isChangingHUD = false }
        }
    }

    // MARK: - Display and synchronization

    func setMSyncEnabled(_ enabled: Bool, in bottle: Bottle) {
        guard !library.isLoading, let bottle = library.bottles.first(where: { $0.id == bottle.id }),
              runtimes.supportsMSync(bottle) else { return }
        guard !activity.activity(for: bottle).blocksPrefixMutation, bottle.msyncEnabled != enabled else { return }
        activity.perform(in: bottle, title: "Changing synchronization…") {
            let updated = try await self.wine.configureSynchronization(msyncEnabled: enabled, in: bottle)
            self.library.replace(updated)
            return nil
        }
    }

    func setRetinaEnabled(_ enabled: Bool, in bottle: Bottle) {
        guard !library.isLoading, let bottle = library.bottles.first(where: { $0.id == bottle.id }),
              bottle.isInitialized else { return }
        guard !activity.activity(for: bottle).blocksPrefixMutation else { return }
        let dpi: UInt32 = enabled ? 192 : 96
        guard bottle.display.retinaEnabled != enabled || bottle.display.dpi != dpi else { return }

        activity.perform(in: bottle, title: "Changing display settings…") {
            let updated = try await self.wine.configureDisplay(retinaEnabled: enabled, in: bottle)
            self.library.replace(updated)
            return nil
        }
    }

    // MARK: - Compatibility switches

    func rosettaAVXAvailability(_ bottle: Bottle) -> RosettaAVXAvailability {
        wine.rosettaAVXAvailability(bottle.runtime)
    }

    /// Launch switches only, like the HUD: running programs keep going and those launched
    /// afterwards use the new setting. No exclusive operation title is shown.
    func setCompatibility(_ options: CompatibilityOptions, in bottle: Bottle) {
        guard !library.isLoading, let bottle = library.bottles.first(where: { $0.id == bottle.id }),
              bottle.compatibility != options, !activity.activity(for: bottle).blocksLibraryEdit,
              changingCompatibility.insert(bottle.id).inserted else { return }
        Task {
            do {
                library.replace(try await store.setCompatibility(options, in: bottle))
            } catch {
                activity.recordError(error, for: bottle.id)
            }
            changingCompatibility.remove(bottle.id)
        }
    }

    // MARK: - Program launch options

    /// Metadata only, like Add/Remove Program: allowed while programs run, and the next
    /// launch of this program uses the new options. Errors return to the editor sheet.
    func saveProgram(_ program: WindowsProgram, from original: WindowsProgram, in bottle: Bottle) async throws {
        guard !activity.activity(for: bottle).blocksLibraryEdit else {
            throw MagicWineError.busy("This bottle’s operation must finish before the program is saved.", reason: .operationInProgress)
        }
        library.replace(try await store.updateProgram(program, from: original, in: library.current(bottle)))
    }
}
