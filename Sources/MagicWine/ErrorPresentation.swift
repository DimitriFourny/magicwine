import SwiftUI
import MagicWineCore

/// A failure as the app presents it: the message, surface-neutral guidance, the log that
/// explains it, and what may fix it (`MagicWineError.recoveryActions`).
struct PresentedError: Equatable {
    /// The card's heading: what kind of failure this is.
    let title: String
    let message: String
    let recoverySuggestion: String?
    let logURL: URL?
    let actions: [RecoveryAction]

    init(_ error: any Error) {
        if let error = error as? MagicWineError {
            title = if case .newerVersion = error { localized("Saved by a Newer MagicWine") } else { localized("Operation Failed") }
            message = error.errorDescription ?? error.localizedDescription
            recoverySuggestion = error.recoverySuggestion
            logURL = error.logURL
            actions = error.recoveryActions
        } else {
            title = localized("Operation Failed")
            message = error.localizedDescription
            recoverySuggestion = nil
            logURL = nil
            actions = []
        }
    }

    /// Message and guidance in one text, for alerts.
    var text: String { [message, recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n") }
}

extension AppNotice {
    init(title: String, error: any Error) {
        let presented = PresentedError(error)
        self.init(title: title, message: presented.text, logURL: presented.logURL)
    }
}

/// A failed bottle operation: what happened, what may fix it, its log, and buttons for
/// the recovery actions this app can perform for the bottle as it is now.
struct OperationErrorCard: View {
    let model: AppModel
    let bottle: Bottle
    let error: PresentedError
    @Environment(\.openWindow) private var openWindow
    @Environment(\.newBottle) private var newBottle
    @State private var confirmsComponentUpdate = false

    private var activity: BottleActivity { model.activity.activity(for: bottle) }
    private var actions: [RecoveryAction] { error.actions.filter { $0.isAvailable(for: bottle) } }

    var body: some View {
        WineCard(verbatimTitle: error.title, icon: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: 12) {
                Text(error.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let suggestion = error.recoverySuggestion {
                    Text(suggestion)
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                HStack(spacing: 9) {
                    if let log = error.logURL {
                        Button("Show Log") { openWindow(id: LogViewerView.windowID, value: log) }
                    } else {
                        Button("Show Logs") { openWindow(id: BottleLogsView.windowID, value: bottle.id) }
                    }
                    ForEach(actions, id: \.self) { action in
                        actionButton(action)
                    }
                    Button("Dismiss") { model.activity.dismissError(for: bottle) }
                }
                .buttonStyle(WineButtonStyle())
                // The existing Update Wine entry point, with its unsigned-runtime confirmation.
                if actions.contains(.updateWine), model.runtimes.canUpgradeRuntime(bottle) {
                    WineInstallationView(model: model, bottle: bottle)
                }
            }
        }
        .alert("Update \(bottle.graphics.backend.displayName) component?", isPresented: $confirmsComponentUpdate) {
            Button("Update") { model.bottleSettings.updateGraphicsComponent(in: bottle) }
                .disabled(activity.blocksPrefixMutation)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(GraphicsSettingsView.componentUpdateMessage(for: bottle))
        }
    }

    /// Only actions the app performs itself get a button; the guidance covers the rest.
    @ViewBuilder
    private func actionButton(_ action: RecoveryAction) -> some View {
        switch action {
        case .stopBottle:
            Button("Stop") { model.activity.stop(bottle) }
                .disabled(activity.isStopping || activity.graphicsSetupID != nil)
        case .retrySetup:
            Button("Retry Setup") { model.activity.initialize(bottle) }
                .disabled(activity.blocksPrefixMutation)
        case .restoreStandardGraphics:
            Button("Restore Standard Graphics") { model.bottleSettings.setGraphics(.standard, in: bottle) }
                .disabled(model.library.isLoading || activity.blocksPrefixMutation)
        case .updateGraphicsComponent:
            Button("Update Component…") { confirmsComponentUpdate = true }
                .disabled(model.library.isLoading || activity.blocksPrefixMutation)
        case .chooseWine:
            Button("New Bottle with Other Wine…") { newBottle?() }
                .disabled(model.library.isLoading || newBottle == nil)
        case .reload:
            Button("Reload") { model.refreshBottles() }
                .disabled(model.library.isLoading || activity.blocksLibraryEdit)
        case .showLog, .updateWine, .installRosetta, .giveConsent, .retry, .chooseProgramGraphics:
            EmptyView()
        }
    }
}
