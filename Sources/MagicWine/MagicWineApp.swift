import SwiftUI
import MagicWineCore

@main
struct MagicWineApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
                .frame(minWidth: 820, minHeight: 560)
                .task { await model.start() }
                .onOpenURL { model.openInstallerURL($0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Bottle…") { model.showsNewBottle = true }
                    .keyboardShortcut("n")
                    .disabled(model.isLoading)
            }
            CommandMenu("Bottle") {
                Button("Install EXE/MSI…") {
                    if let bottle = model.selectedBottle { model.chooseInstaller(in: bottle) }
                }
                .disabled(!canUseSelectedBottle)
                Button("Stop Windows Processes") {
                    if let bottle = model.selectedBottle { model.stop(bottle) }
                }
                .disabled(!canStopSelectedBottle)
                Divider()
                Button("Reveal Logs") { model.revealLogs(for: model.selectedBottle) }
                Button("Reload Bottles") { model.refreshBottles() }
                    .disabled(model.isLoading)
            }
        }

        Settings {
            WineSettingsView(model: model)
                .frame(width: 620)
                .padding(24)
        }
    }

    private var canUseSelectedBottle: Bool {
        guard let bottle = model.selectedBottle else { return false }
        let state = model.activity(for: bottle)
        return bottle.isInitialized && state.title == nil && !state.isStopping
    }

    private var canStopSelectedBottle: Bool {
        guard let bottle = model.selectedBottle else { return false }
        let state = model.activity(for: bottle)
        return !state.isStopping && (state.canStop || (state.title == nil && bottle.isInitialized))
    }
}

private struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var trashTarget: Bottle?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedBottleID) {
                ForEach(model.bottles) { bottle in
                    HStack {
                        Image(systemName: "shippingbox")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(bottle.name)
                            if let title = model.activity(for: bottle).title {
                                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            } else if !bottle.isInitialized {
                                Text("Setup needed").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(bottle.id)
                    .contextMenu {
                        Button("Reveal Logs") { model.revealLogs(for: bottle) }
                        Button("Move Bottle to Trash…", role: .destructive) { trashTarget = bottle }
                            .disabled(model.activity(for: bottle).title != nil || model.activity(for: bottle).isStopping)
                    }
                }
            }
            .navigationTitle("Bottles")
            .navigationSplitViewColumnWidth(min: 190, ideal: 235)
            .overlay {
                if model.bottles.isEmpty {
                    Text(model.isLoading ? "Loading bottles…" : "Your bottles will appear here.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
            }
            .toolbar {
                ToolbarItem {
                    Button { model.showsNewBottle = true } label: {
                        Label("New Bottle", systemImage: "plus")
                    }
                    .help("Create a bottle")
                    .disabled(model.isLoading)
                }
            }
        } detail: {
            if let bottle = model.selectedBottle {
                BottleDetailView(model: model, bottle: bottle, trash: { trashTarget = bottle })
                    .id(bottle.id)
            } else {
                WelcomeView(model: model)
            }
        }
        .sheet(isPresented: $model.showsNewBottle) {
            NewBottleView(model: model)
        }
        .alert(item: $model.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.message),
                  primaryButton: .default(Text("OK")),
                  secondaryButton: .default(Text("Reveal Logs"), action: { model.revealLogs() }))
        }
        .confirmationDialog("Move Bottle to Trash?", isPresented: Binding(
            get: { trashTarget != nil },
            set: { if !$0 { trashTarget = nil } }
        ), titleVisibility: .visible) {
            if let bottle = trashTarget {
                Button("Move \(bottle.name) to Trash", role: .destructive) {
                    model.trash(bottle)
                    trashTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { trashTarget = nil }
        } message: {
            Text("This moves the bottle and its Windows files to macOS Trash. Programs outside the bottle are not deleted. Stop all Windows processes in the bottle first.")
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Welcome to MagicWine").font(.largeTitle)
                Text("A bottle keeps a Windows environment, its programs, and its Wine version together.")
                    .foregroundStyle(.secondary)
                if model.isLoading {
                    ProgressView("Loading your library…")
                } else if model.runtimes.isEmpty {
                    Text("Set Up Wine").font(.title2)
                    Text("Install a separately maintained Wine runtime or choose a Wine executable already on your Mac. Then create your first bottle.")
                    RuntimeSetupView(model: model)
                } else {
                    Button("Create Bottle…") { model.showsNewBottle = true }
                        .buttonStyle(.borderedProminent)
                    Text("Or select a bottle in the sidebar.").foregroundStyle(.secondary)
                    SettingsLink { Text("Wine Settings…") }
                }
            }
            .padding(32)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("MagicWine")
    }
}

private struct BottleDetailView: View {
    @ObservedObject var model: AppModel
    let bottle: Bottle
    let trash: () -> Void

    private var state: BottleActivity { model.activity(for: bottle) }
    private var busy: Bool { state.title != nil || state.isStopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(bottle.name).font(.title)
                        Text(bottle.runtime.version).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(state.isStopping ? "Stopping…" : "Stop") { model.stop(bottle) }
                        .disabled(state.isStopping || (!state.canStop && (state.title != nil || !bottle.isInitialized)))
                        .help("Stop all Windows processes in this bottle")
                }
                DisclosureGroup("Bottle Information") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Wine executable: \(bottle.runtime.executableURL.path)")
                        Text("This bottle keeps this runtime. Wine Settings only changes the default for new bottles.")
                        Text("Created \(bottle.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    }
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
                if let title = state.title {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(state.isStopping ? "Stopping Windows processes…" : title)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let error = state.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Operation Failed", systemImage: "exclamationmark.triangle").font(.headline)
                        Text(error).textSelection(.enabled)
                        HStack {
                            Button("Reveal Logs") { model.revealLogs(for: bottle) }
                            Button("Dismiss") { model.dismissError(for: bottle) }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
                if !bottle.isInitialized {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This bottle needs setup before you can run programs.")
                        Text("If setup fails, the bottle stays here so you can resolve the error and retry.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Retry Setup") { model.initialize(bottle) }
                            .disabled(busy)
                    }
                }
                HStack {
                    Button("Install EXE/MSI…") { model.chooseInstaller(in: bottle) }
                    Button("Add Program…") { model.chooseProgram(in: bottle) }
                    Button { model.refreshPrograms(in: bottle) } label: {
                        Label("Refresh Shortcuts", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(busy || !bottle.isInitialized)
            }
            .padding(22)

            Divider()
            if bottle.programs.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "app.dashed").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("No Programs Yet").font(.title2)
                    Text("Install an EXE or MSI, or add an existing Windows program. Refresh Shortcuts finds Start Menu and Desktop shortcuts after installation.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 450)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            } else {
                List {
                    ForEach(bottle.programs) { program in
                        HStack(spacing: 12) {
                            Image(systemName: "app")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(program.name).font(.headline)
                                Text(program.executablePath).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Launch") { model.launch(program, in: bottle) }
                                .disabled(busy || !bottle.isInitialized)
                            Menu {
                                Button("Remove from MagicWine", role: .destructive) {
                                    model.removeProgram(program, in: bottle)
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .disabled(busy)
                            .help("Program actions; removal does not delete the executable")
                        }
                        .padding(.vertical, 5)
                        .contextMenu {
                            Button("Launch") { model.launch(program, in: bottle) }
                                .disabled(busy || !bottle.isInitialized)
                            Button("Remove from MagicWine", role: .destructive) {
                                model.removeProgram(program, in: bottle)
                            }
                            .disabled(busy)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Wine Configuration…") { model.configure(bottle) }
                    .disabled(busy || !bottle.isInitialized)
                Button("Reveal C: Drive") { model.revealDrive(bottle) }
                    .disabled(!bottle.isInitialized)
                Button("Reveal Logs") { model.revealLogs(for: bottle) }
                Spacer()
                Button("Trash Bottle…", role: .destructive, action: trash)
                    .disabled(busy)
            }
            .padding(16)
        }
        .navigationTitle(bottle.name)
    }
}

private struct NewBottleView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var runtimeID = ""

    private var runtime: RuntimeDescriptor? {
        model.runtimes.first { $0.id == runtimeID } ?? model.preferredRuntime
    }
    private var validName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Bottle").font(.title2)
            if model.runtimes.isEmpty {
                Text("Choose or install Wine before creating a bottle.")
                RuntimeSetupView(model: model)
            } else {
                TextField("Bottle name", text: $name).textFieldStyle(.roundedBorder)
                    .onSubmit { create() }
                    .disabled(model.isCreating)
                Picker("Wine runtime", selection: Binding(
                    get: { runtime?.id ?? "" },
                    set: { runtimeID = $0 }
                )) {
                    ForEach(model.runtimes) { runtime in
                        Text("\(runtime.version) — \(runtime.executableURL.deletingLastPathComponent().path)")
                            .tag(runtime.id)
                    }
                }
                .disabled(model.isCreating || model.runtimeActivity != nil)
                Text("The bottle keeps the selected runtime, even if you later choose a different default.")
                    .font(.callout).foregroundStyle(.secondary)
                if let runtime {
                    Text(runtime.executableURL.path).font(.caption).textSelection(.enabled)
                }
                if model.isCreating { ProgressView("Creating bottle…") }
            }
            if let error = model.creationError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                Button("Reveal Logs") { model.revealLogs() }
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCreating)
                Spacer()
                Button("Create Bottle", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validName || runtime == nil || model.isCreating || model.runtimeActivity != nil)
            }
        }
        .padding(24).frame(width: 550)
        .interactiveDismissDisabled(model.isCreating)
    }

    private func create() {
        guard validName, !model.isCreating, model.runtimeActivity == nil, let runtime else { return }
        model.createBottle(name: name, runtime: runtime)
    }
}

private struct WineSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Wine Runtime").font(.title2)
                Text("Choose the default runtime for new bottles. Existing bottles keep their own runtime.")
                    .foregroundStyle(.secondary)
                if !model.runtimes.isEmpty {
                    Picker("New-bottle default", selection: Binding(
                        get: { model.preferredRuntime?.id ?? "" },
                        set: { model.preferRuntime(id: $0) }
                    )) {
                        ForEach(model.runtimes) { runtime in
                            Text("\(runtime.version) — \(runtime.executableURL.path)").tag(runtime.id)
                        }
                    }
                    .disabled(model.runtimeActivity != nil)
                    if let runtime = model.preferredRuntime {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(runtime.version).font(.headline)
                            Text(runtime.executableURL.path).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                if let path = model.settings.customWinePath {
                    Text("Saved custom executable: \(path)").font(.caption).textSelection(.enabled)
                }
                RuntimeSetupView(model: model)
                HStack {
                    Button("Find Installed Wine") { model.refreshRuntimes() }
                        .disabled(model.runtimeActivity != nil)
                    Button("Reveal Logs") { model.revealLogs() }
                }
            }
        }
    }
}

private struct RuntimeSetupView: View {
    @ObservedObject var model: AppModel
    @State private var confirmInstall = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button("Install / Update Wine…") { confirmInstall = true }
                    .buttonStyle(.borderedProminent)
                Button("Choose Wine Executable…") { model.chooseWineExecutable() }
            }
            .disabled(model.runtimeActivity != nil)
            Text("Managed downloads come from Gcenx/macOS_Wine_builds, a separately maintained third-party Wine distribution. Installing an update changes the default for new bottles, not existing bottles.")
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("Windows Multimedia") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Windows multimedia may require GStreamer 1.28.2 or newer (Universal runtime), installed separately in /Library/Frameworks/GStreamer.framework.")
                    Text("MagicWine does not install system frameworks.")
                    Link("Download GStreamer", destination: URL(string: "https://gstreamer.freedesktop.org/download/")!)
                }
                .font(.callout).padding(.top, 8)
            }
            if let activity = model.runtimeActivity { ProgressView(activity) }
            if let error = model.runtimeError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Wine Setup Failed", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).textSelection(.enabled)
                    Button("Reveal Logs") { model.revealLogs() }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            #if arch(arm64)
            DisclosureGroup("Rosetta on Apple Silicon") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Intel Wine requires Apple's Rosetta. If Wine reports that Rosetta is missing, install it yourself after reviewing Apple's license. MagicWine does not install it or accept the license for you.")
                    Text("In Terminal, run:")
                    Text("softwareupdate --install-rosetta")
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Text("Read the license prompt and choose whether to accept, then retry Wine setup.")
                    Link("Apple's Rosetta Instructions", destination: URL(string: "https://support.apple.com/102527")!)
                }
                .font(.callout).padding(.top, 8)
            }
            #endif
        }
        .confirmationDialog("Trust Third-Party Wine?", isPresented: $confirmInstall, titleVisibility: .visible) {
            Button("Trust and Install Wine") { model.installWine() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This Wine build is not notarized by Apple. MagicWine checks its download checksum and removes this bundle’s quarantine to let it run. This is not a malware check; system-wide security settings are unchanged.")
        }
    }
}
