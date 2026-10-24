import SwiftUI
import MagicWineCore

/// A window-specific action handed to menu commands through `FocusedValues` and to the
/// window's views through the environment.
struct WindowAction {
    let perform: @MainActor () -> Void

    @MainActor
    func callAsFunction() { perform() }
}

private struct SelectedBottleKey: FocusedValueKey { typealias Value = UUID }
private struct SelectedProgramKey: FocusedValueKey { typealias Value = UUID }
private struct FileImportFocusKey: FocusedValueKey { typealias Value = FileImportAction }
private struct NewBottleKey: FocusedValueKey { typealias Value = WindowAction }

private struct NewBottleActionKey: EnvironmentKey {
    static let defaultValue: WindowAction? = nil
}

extension EnvironmentValues {
    /// Opens this library window's New Bottle sheet.
    var newBottle: WindowAction? {
        get { self[NewBottleActionKey.self] }
        set { self[NewBottleActionKey.self] = newValue }
    }
}

extension FocusedValues {
    /// The focused library window's selected bottle.
    var selectedBottleID: UUID? {
        get { self[SelectedBottleKey.self] }
        set { self[SelectedBottleKey.self] = newValue }
    }

    /// The program selected in the focused window's bottle dashboard.
    var selectedProgramID: UUID? {
        get { self[SelectedProgramKey.self] }
        set { self[SelectedProgramKey.self] = newValue }
    }

    /// The focused library window's file dialog.
    var fileImport: FileImportAction? {
        get { self[FileImportFocusKey.self] }
        set { self[FileImportFocusKey.self] = newValue }
    }

    /// Opens the focused library window's New Bottle sheet.
    var newBottle: WindowAction? {
        get { self[NewBottleKey.self] }
        set { self[NewBottleKey.self] = newValue }
    }
}

/// File › New Bottle… for the focused library window.
struct NewBottleCommand: View {
    let model: AppModel
    @FocusedValue(\.newBottle) private var newBottle

    var body: some View {
        Button("New Bottle…") { newBottle?() }
            .keyboardShortcut("n")
            .disabled(model.library.isLoading || newBottle == nil)
    }
}

/// The Bottle menu: acts on the focused library window's selected bottle and program, and is
/// enabled by the same `BottleActivity` predicates as the dashboard and toolbar. Menu
/// commands cannot read a window's `openWindow` or file dialog from the app; a view can.
struct BottleCommands: View {
    let model: AppModel
    @FocusedValue(\.selectedBottleID) private var bottleID
    @FocusedValue(\.selectedProgramID) private var programID
    @FocusedValue(\.fileImport) private var fileImport
    @Environment(\.openWindow) private var openWindow

    private var bottle: Bottle? {
        bottleID.flatMap { id in model.library.bottles.first { $0.id == id } }
    }

    private var program: WindowsProgram? {
        programID.flatMap { id in bottle?.programs.first { $0.id == id } }
    }

    private var state: BottleActivity {
        bottle.map(model.activity.activity(for:)) ?? BottleActivity()
    }

    private var initialized: Bool { bottle?.isInitialized == true }

    var body: some View {
        Button("Install EXE/MSI…") { if let bottle { fileImport?(.installer(bottle)) } }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!initialized || state.blocksPrefixMutation || fileImport == nil)
        Button("Add Program…") { if let bottle { fileImport?(.program(bottle)) } }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!initialized || state.blocksLibraryEdit || fileImport == nil)
        Button("Refresh Programs") { if let bottle { model.activity.refreshPrograms(in: bottle) } }
            .keyboardShortcut("r")
            .disabled(!initialized || state.blocksLibraryEdit)
        Divider()
        Button(program.map { localized("Launch \($0.name)") } ?? localized("Launch Program")) {
            if let bottle, let program { model.activity.launch(program, in: bottle) }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(program == nil || !initialized || state.blocksLaunch)
        Button("Stop Windows Processes") { if let bottle { model.activity.stop(bottle) } }
            // Not ⌘., which macOS reserves for Cancel in sheets and dialogs.
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(bottle.map { !state.allowsStop(of: $0) } ?? true)
        Divider()
        Button("Show Bottle Logs…") { if let bottle { openWindow(id: BottleLogsView.windowID, value: bottle.id) } }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            .disabled(bottle == nil)
        Button("Reveal C: Drive") { if let bottle { Finder.reveal(model.library.driveURL(for: bottle)) } }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!initialized)
        Divider()
        Button("Reload Bottles") { model.refreshBottles() }
            .disabled(model.library.isLoading)
    }
}
