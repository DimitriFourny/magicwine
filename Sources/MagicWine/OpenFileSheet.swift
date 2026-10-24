import SwiftUI
import MagicWineCore

/// Asks which set-up bottle, and which action, to use for a Windows file opened from Finder.
/// Nothing runs until the user confirms; Cancel leaves the file untouched.
struct OpenFileSheet: View {
    let model: AppModel
    let file: OpenedFile
    /// The window's selected bottle; used when it is set up.
    let preferredBottleID: UUID?
    /// Closes the sheet and opens the file in a new bottle, started from the sheet's button.
    let createBottle: (OpenedFileAction) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var action: OpenedFileAction
    @State private var bottleID: UUID?

    init(model: AppModel, file: OpenedFile, preferredBottleID: UUID?,
         createBottle: @escaping (OpenedFileAction) -> Void) {
        self.model = model
        self.file = file
        self.preferredBottleID = preferredBottleID
        self.createBottle = createBottle
        _action = State(initialValue: file.actions[0])
        let ready = model.library.bottles.filter(\.isInitialized)
        _bottleID = State(initialValue: ready.first { $0.id == preferredBottleID }?.id ?? ready.first?.id)
    }

    private var readyBottles: [Bottle] { model.library.bottles.filter(\.isInitialized) }
    private var bottle: Bottle? { readyBottles.first { $0.id == bottleID } }

    /// Why the chosen bottle cannot take the action now, using the same predicates as the
    /// Install EXE/MSI and Add Program buttons.
    private var blockedReason: String? {
        guard let bottle else { return nil }
        let state = model.activity.activity(for: bottle)
        switch action {
        case .install where state.blocksPrefixMutation:
            return "\(bottle.name) is busy or has programs running. Installers need it idle; wait or stop its programs."
        case .addProgram where state.blocksLibraryEdit:
            return "\(bottle.name) is busy. Wait for its operation to finish."
        default:
            return nil
        }
    }

    private var confirmTitle: String {
        switch action {
        case .install: "Run Installer"
        case .addProgram: "Add Program"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Open “\(file.url.lastPathComponent)”").font(.title2)
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if file.actions.count > 1 {
                Picker("Action", selection: $action) {
                    Text("Run Installer").tag(OpenedFileAction.install)
                    Text("Add as Program").tag(OpenedFileAction.addProgram)
                }
                .pickerStyle(.segmented)
            }
            Text(actionDescription)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if readyBottles.isEmpty {
                Label("No bottle is set up yet. Create one to continue.", systemImage: "shippingbox")
                    .font(.callout)
            } else {
                Picker("Bottle", selection: $bottleID) {
                    ForEach(readyBottles) { bottle in
                        Text(bottle.name).tag(Optional(bottle.id))
                    }
                }
            }
            if let blockedReason {
                Label(blockedReason, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(WineTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("New Bottle…") { createBottle(action) }
                    .disabled(model.library.isCreating)
                Spacer()
                Button(confirmTitle) {
                    guard let bottle else { return }
                    model.open(file, as: action, in: bottle)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(bottle == nil || blockedReason != nil)
            }
        }
        .padding(24).frame(width: 480)
    }

    private var actionDescription: String {
        switch action {
        case .install:
            "Runs the installer in the bottle. It may change the bottle’s Windows files, and MagicWine then looks for the shortcuts it created."
        case .addProgram:
            "Adds the file to the bottle’s programs where it is, without moving or copying it. Removing it later does not delete the file."
        }
    }
}
