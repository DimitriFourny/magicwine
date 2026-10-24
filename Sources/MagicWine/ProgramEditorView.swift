import AppKit
import SwiftUI
import MagicWineCore

/// Edits a saved program's name and launch options. Metadata only: allowed while
/// programs run; the next launch of this program uses the saved options.
struct ProgramEditorView: View {
    @ObservedObject var model: AppModel
    let bottle: Bottle
    let original: WindowsProgram
    @Environment(\.dismiss) private var dismiss

    private struct Variable: Identifiable {
        let id = UUID()
        var key: String
        var value: String
    }

    private struct Override: Identifiable {
        let id = UUID()
        var name: String
        var mode: DLLOverrides.Mode
    }

    @State private var name: String
    @State private var argumentsText: String
    @State private var workingDirectory: String?
    @State private var variables: [Variable]
    @State private var overrides: [Override]
    @State private var isSaving = false
    @State private var error: String?

    init(model: AppModel, bottle: Bottle, program: WindowsProgram) {
        self.model = model
        self.bottle = bottle
        original = program
        _name = State(initialValue: program.name)
        _argumentsText = State(initialValue: WindowsProgram.formatArguments(program.arguments))
        _workingDirectory = State(initialValue: program.workingDirectory)
        _variables = State(initialValue: program.environment.keys.sorted().map {
            Variable(key: $0, value: program.environment[$0] ?? "")
        })
        _overrides = State(initialValue: program.dllOverrides.entries.map { Override(name: $0.dll, mode: $0.mode) })
    }

    private var parsedArguments: Result<[String], Error> {
        Result { try WindowsProgram.parseArguments(argumentsText) }
    }

    private func variableProblem(_ variable: Variable) -> String? {
        let key = variable.key.trimmingCharacters(in: .whitespaces)
        if key.isEmpty { return variable.value.isEmpty ? nil : "Enter a variable name." }
        if variables.filter({ $0.key.trimmingCharacters(in: .whitespaces) == key }).count > 1 {
            return "\(key) is listed more than once."
        }
        return WindowsProgram.environmentKeyProblem(key) ?? WindowsProgram.environmentValueProblem(variable.value)
    }

    private func overrideProblem(_ override: Override) -> String? {
        let trimmed = override.name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        guard let name = try? DLLOverrides.validatedName(trimmed) else {
            return "Use a DLL module name such as d3d11, without a path."
        }
        if overrides.filter({ (try? DLLOverrides.validatedName($0.name)) == name }).count > 1 {
            return "\(name) is listed more than once."
        }
        return nil
    }

    /// The edited record, or the first problem preventing a save.
    private var edited: Result<WindowsProgram, Error> {
        Result {
            var program = original
            program.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !program.name.isEmpty, program.name.count <= 80 else { throw MagicWineError.invalidName }
            if original.supportsArgumentsAndDirectory {
                program.arguments = try parsedArguments.get()
                program.workingDirectory = workingDirectory
            }
            program.environment = [:]
            for variable in variables {
                if let problem = variableProblem(variable) { throw MagicWineError.setup(problem) }
                let key = variable.key.trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { program.environment[key] = variable.value }
            }
            program.dllOverrides = DLLOverrides()
            for override in overrides where !override.name.trimmingCharacters(in: .whitespaces).isEmpty {
                if let problem = overrideProblem(override) { throw MagicWineError.setup(problem) }
                try program.dllOverrides.set(override.mode, for: override.name)
            }
            try program.validateLaunchOptions()
            return program
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit \(original.name)").font(.title2)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section("Name") {
                        TextField("Program name", text: $name).textFieldStyle(.roundedBorder)
                    }
                    if original.supportsArgumentsAndDirectory {
                        argumentsSection
                        workingDirectorySection
                    } else {
                        Text("Wine opens this shortcut with its own arguments and folder, so only environment variables and DLL overrides apply. A shortcut handed to an already running launcher (such as a Steam URL) uses that launcher’s settings instead.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    environmentSection
                    overridesSection
                }
                .padding(.trailing, 8)
            }
            Text("Saved options apply the next time this program launches. Running programs keep their current settings.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || (try? edited.get()) == nil || model.activity(for: bottle).blocksLibraryEdit)
            }
        }
        .padding(24)
        .frame(width: 600, height: 620)
        .interactiveDismissDisabled(isSaving)
    }

    private var argumentsSection: some View {
        section("Arguments") {
            TextField("For example: -windowed -config \"My Settings.ini\"", text: $argumentsText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            switch parsedArguments {
            case .success(let tokens) where tokens.isEmpty:
                hint("Separate arguments with spaces. Quote an argument containing spaces with \"…\" or '…'. Backslashes are kept as typed.")
            case .success(let tokens):
                hint("Passed as \(tokens.count) argument\(tokens.count == 1 ? "" : "s"): " +
                     tokens.map { "‹\($0)›" }.joined(separator: " "))
            case .failure(let failure):
                problem(failure.localizedDescription)
            }
        }
    }

    private var workingDirectorySection: some View {
        section("Working Directory") {
            HStack(spacing: 8) {
                Text(workingDirectory ?? "The program’s folder (default)")
                    .font(.callout)
                    .foregroundStyle(workingDirectory == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(workingDirectory ?? URL(fileURLWithPath: original.executablePath).deletingLastPathComponent().path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose…", action: chooseFolder)
                Button("Reset") { workingDirectory = nil }
                    .disabled(workingDirectory == nil)
            }
        }
    }

    private var environmentSection: some View {
        section("Environment Variables") {
            ForEach($variables) { $variable in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("NAME", text: $variable.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 200)
                        TextField("value", text: $variable.value)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                        removeButton { variables.removeAll { $0.id == variable.id } }
                    }
                    if let message = variableProblem(variable) { problem(message) }
                }
            }
            Button("Add Variable") { variables.append(Variable(key: "", value: "")) }
            hint("These win over bottle and graphics settings for this program, for example WINEDEBUG, DXVK_HUD, or MTL_HUD_ENABLED. Prefix, loader, server, PATH, DYLD_*, and MagicWine’s own variables cannot be changed.")
        }
    }

    private var overridesSection: some View {
        section("DLL Overrides") {
            ForEach($overrides) { $override in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("DLL name, e.g. d3d11", text: $override.name)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.callout, design: .monospaced))
                            .frame(width: 200)
                        Picker("Load order", selection: $override.mode) {
                            ForEach(DLLOverrides.Mode.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                        removeButton { overrides.removeAll { $0.id == override.id } }
                    }
                    if let message = overrideProblem(override) { problem(message) }
                }
            }
            Button("Add DLL Override") { overrides.append(Override(name: "", mode: .nativeThenBuiltin)) }
            hint("These replace MagicWine’s load order for the same DLL in this program only. Native means the Windows DLL in the program or prefix; builtin means Wine’s own.")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func problem(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove")
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Working Directory"
        panel.message = "The program starts in this Mac folder. It must still exist when the program launches."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: workingDirectory ?? original.executablePath).deletingLastPathComponent()
        panel.begin { response in
            Task { @MainActor in
                if response == .OK, let url = panel.url { workingDirectory = url.standardizedFileURL.path }
            }
        }
    }

    private func save() {
        guard !isSaving else { return }
        let program: WindowsProgram
        switch edited {
        case .success(let value): program = value
        case .failure(let failure):
            error = failure.localizedDescription
            return
        }
        guard program != original else { dismiss(); return }
        isSaving = true
        error = nil
        Task {
            do {
                try await model.saveProgram(program, from: original, in: bottle)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}
