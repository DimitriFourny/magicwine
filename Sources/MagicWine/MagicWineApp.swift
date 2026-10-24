import SwiftUI
import MagicWineCore

@main
struct MagicWineApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @StateObject private var model = AppModel(paths: ApplicationPaths(
        root: ProcessInfo.processInfo.environment["MAGICWINE_DATA_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    ))

    var body: some Scene {
        WindowGroup {
            LibraryView(model: model)
                .frame(minWidth: 1000, minHeight: 720)
                .preferredColorScheme(.dark)
                .task { await model.start() }
                .onOpenURL { model.openInstallerURL($0) }
        }
        .defaultSize(width: 1440, height: 960)
        .windowStyle(.hiddenTitleBar)
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
                .background(WineTheme.background)
                .preferredColorScheme(.dark)
        }
    }

    private var canUseSelectedBottle: Bool {
        guard let bottle = model.selectedBottle else { return false }
        let state = model.activity(for: bottle)
        return bottle.isInitialized && !state.blocksPrefixMutation
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
    @State private var destination: LibraryDestination = .bottles
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            LibrarySidebarView(model: model, destination: $destination, search: $search,
                               trash: { trashTarget = $0 })
                .frame(width: 250)
            Rectangle().fill(WineTheme.border).frame(width: 1)
            VStack(spacing: 0) {
                Group {
                    switch destination {
                    case .bottles:
                        if let bottle = model.selectedBottle {
                            BottleDashboardView(model: model, bottle: bottle, trash: { trashTarget = bottle })
                                .id(bottle.id)
                        } else {
                            WelcomeView(model: model)
                        }
                    case .gamepads:
                        GamepadView(paths: model.paths)
                    case .downloads:
                        downloads
                    case .settings:
                        WineSettingsView(model: model).padding(24)
                    case .documentation:
                        documentation
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(WineTheme.text)
        .background(WineTheme.background)
        .tint(WineTheme.accent)
        .buttonStyle(WineButtonStyle())
        .sheet(isPresented: $model.showsNewBottle) {
            NewBottleView(model: model)
        }
        .alert(model.notice?.title ?? "", isPresented: Binding(
            get: { model.notice != nil },
            set: { if !$0 { model.notice = nil } }
        ), presenting: model.notice) { notice in
            Button("OK", role: .cancel) { }
            if let log = notice.logURL {
                Button("Reveal Log") { model.reveal(log) }
            }
        } message: { notice in
            Text(notice.message)
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

    private var downloads: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Downloads").font(.system(size: 32, weight: .semibold, design: .serif))
                Text("Install Wine for new bottles. To update an existing bottle, use Update Wine in its dashboard.")
                    .foregroundStyle(WineTheme.muted)
                WineCard(title: "Wine Runtime", icon: "arrow.down.to.line") {
                    RuntimeSetupView(model: model)
                }
                if !model.runtimes.isEmpty {
                    WineCard(title: "Available Runtimes", icon: "wineglass", trailing: "\(model.runtimes.count) installed") {
                        ForEach(model.runtimes) { runtime in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(runtime.version).font(.headline)
                                Text(runtime.executableURL.path)
                                    .font(.caption).foregroundStyle(WineTheme.muted)
                                    .textSelection(.enabled)
                            }
                            if runtime.id != model.runtimes.last?.id { Divider() }
                        }
                    }
                }
            }
            .padding(24).frame(maxWidth: 850, alignment: .leading)
        }
    }

    private var documentation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("A little bottled knowledge.")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                Text("Everything you need to get started.")
                    .foregroundStyle(WineTheme.muted)
                WineCard(title: "Your First Windows Program", icon: "book") {
                    Text("1. Install Wine in Downloads. Custom Wine executables are available in Settings under Advanced.")
                    Text("2. Create a bottle with the + button. Each bottle keeps its own runtime and Windows files.")
                    Text("3. Install an EXE/MSI, complete the Windows installer, and launch a discovered shortcut.")
                    Text("4. Use Add Program for an existing EXE/LNK/URL, or Refresh Shortcuts after installation.")
                }
                WineCard(title: "Graphics & Compatibility", icon: "gamecontroller") {
                    Text("Standard uses Wine’s built-in graphics. Bundled DXVK translates Direct3D 9/10/11 through Vulkan/MoltenVK; bundled DXMT translates Direct3D 10/11 through Metal. Imported D3DMetal supports 64-bit Direct3D 11/12.")
                    Text("Wine includes MagicWine’s pinned, source-built driver for DXMT and D3DMetal. Standard is the default. Bundled DXMT needs Apple Silicon and macOS 15 or newer; D3DMetal uses your locally installed Apple libraries with the same managed Wine.")
                    Text("D3DMetal is not bundled or downloaded. MagicWine finds local libraries beside the bottle’s Wine or in CrossOver under Applications, and asks for a folder only when none are found. You remain responsible for the terms accompanying your libraries; experimental-backend consent does not accept their license.")
                    Text("Components cannot be upgraded in place. Switch to Standard to restore the original files, then enable a backend again. Direct backend switches preserve the same originals.")
                    Text("Changing graphics stops that bottle’s Windows processes.")
                    Text("Compatibility depends on the Windows program, Wine runtime, and graphics backend. DRM and anti-cheat compatibility are not guaranteed.")
                        .foregroundStyle(WineTheme.muted)
                }
                WineCard(title: "Gamepads", icon: "gamecontroller") {
                    Text("Connect a supported controller by USB or pair it in macOS Bluetooth settings, then open Gamepads. Up to four controllers provide XInput to Windows games.")
                    Text("Edit mappings, calibration, and profiles in the live preview. Save Changes applies the selected profile to all controllers and bottles in this library. Identify requires controller haptics.")
                    Text("Launch games through MagicWine and keep it running. Restart already-running games after updating the app. DirectInput-only games use Wine’s own support; gyro and controller audio are not emulated.")
                }
                WineCard(title: "Your Files & Safety", icon: "lock.shield") {
                    Text("A bottle is not a security sandbox. Only run Windows software you trust.")
                    Text("Removing a launcher does not delete its executable. Trash Bottle moves the bottle’s Windows environment to macOS Trash after stopping its processes.")
                    Text("Current library: \(model.paths.root.path)")
                        .font(.caption).foregroundStyle(WineTheme.muted).textSelection(.enabled)
                    Button("Reveal Logs") { model.revealLogs() }
                }
            }
            .padding(24).frame(maxWidth: 850, alignment: .leading)
        }
    }
}

private struct WelcomeView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 24) {
                    Image(nsImage: WineArtwork.bottle)
                        .resizable().scaledToFit().frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Welcome to MagicWine")
                            .font(.system(size: 34, weight: .regular, design: .serif))
                        Text("Your Windows world, bottled.")
                            .foregroundStyle(WineTheme.muted)
                    }
                }
                Text("A bottle keeps a Windows environment, its programs, and its Wine version together.")
                    .foregroundStyle(WineTheme.muted)
                if model.isLoading {
                    ProgressView("Loading your library…")
                } else if model.preferredRuntime == nil {
                    WineCard(title: "Set Up Wine", icon: "wineglass") {
                        Text("Install Wine, then create your first bottle.")
                            .foregroundStyle(WineTheme.muted)
                        RuntimeSetupView(model: model)
                    }
                } else {
                    Button("Create Bottle…") { model.showsNewBottle = true }
                        .buttonStyle(WineButtonStyle(prominent: true))
                    Text("Or select a bottle in the sidebar.").foregroundStyle(.secondary)
                    SettingsLink { Text("Wine Settings…") }
                }
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
            if runtime == nil {
                Text("Install Wine before creating a bottle.")
                RuntimeSetupView(model: model)
            }
            if !model.runtimes.isEmpty {
                TextField("Bottle name", text: $name).textFieldStyle(.roundedBorder)
                    .onSubmit { create() }
                    .disabled(model.isCreating)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Wine runtime", selection: $runtimeID) {
                            Text("Use preferred Wine").tag("")
                            ForEach(model.runtimes) { runtime in
                                Text("\(runtime.version) — \(runtime.executableURL.deletingLastPathComponent().path)")
                                    .tag(runtime.id)
                            }
                        }
                        .disabled(model.isCreating || model.runtimeActivity != nil)
                        if let runtime {
                            Text(runtime.executableURL.path).font(.caption).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 8)
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
                RuntimeSetupView(model: model)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.runtimes.isEmpty {
                            Picker("Preferred Wine", selection: Binding(
                                get: { model.preferredRuntime?.id ?? "" },
                                set: { model.preferRuntime(id: $0) }
                            )) {
                                if model.preferredRuntime == nil {
                                    Text("No preferred Wine — install or choose one").tag("")
                                }
                                ForEach(model.runtimes) { runtime in
                                    Text("\(runtime.version) — \(runtime.executableURL.path)").tag(runtime.id)
                                }
                            }
                            .disabled(model.runtimeActivity != nil)
                        }
                        Button("Choose Wine Executable…") { model.chooseWineExecutable() }
                            .disabled(model.runtimeActivity != nil)
                        Text("Use a custom runtime for compatibility needs, including D3DMetal. New bottles use your preferred Wine unless you override it.")
                            .font(.callout).foregroundStyle(.secondary)
                        if let path = model.settings.customWinePath {
                            Text("Saved custom executable: \(path)").font(.caption).textSelection(.enabled)
                        }
                        HStack {
                            Button("Find Installed Wine") { model.refreshRuntimes() }
                                .disabled(model.runtimeActivity != nil)
                            Button("Reveal Logs") { model.revealLogs() }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}

private struct RuntimeSetupView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            WineInstallationView(model: model)
            Text("Downloads Wine from Gcenx/macOS_Wine_builds with MagicWine’s bundled, pinned source-built Metal driver bridge. DXMT is also bundled—no additional download is needed to enable it.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Standard graphics is the default. DXMT is optional on Apple Silicon with macOS 15 or newer. D3DMetal uses the same Wine and requires locally installed Apple libraries.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Windows Multimedia") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Windows multimedia may require GStreamer 1.28.2 or newer (Universal runtime), installed separately in /Library/Frameworks/GStreamer.framework.")
                    Text("MagicWine does not install system frameworks.")
                    Link("Download GStreamer", destination: URL(string: "https://gstreamer.freedesktop.org/download/")!)
                }
                .font(.callout).padding(.top, 8)
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
    }
}

struct WineInstallationView: View {
    @ObservedObject var model: AppModel
    var bottle: Bottle? = nil
    @State private var showsTrustConfirmation = false

    private var unavailable: Bool {
        if model.isLoading || model.runtimeActivity != nil { return true }
        guard let bottle else { return false }
        let state = model.activity(for: bottle)
        return state.blocksPrefixMutation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(bottle == nil ? "Install / Update Wine…" : "Update Wine…") {
                showsTrustConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(unavailable)
            if case let .downloading(progress) = model.installationProgress {
                WineDownloadProgressView(progress: progress)
            } else if let activity = model.runtimeActivity {
                ProgressView(activity)
                    .controlSize(.small)
            }
            if let error = model.runtimeError {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Wine Setup Failed", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).textSelection(.enabled)
                    Button("Reveal Logs") { model.revealLogs() }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .confirmationDialog(bottle.map { "Update Wine for \($0.name)?" } ?? "Trust Wine?",
                            isPresented: $showsTrustConfirmation, titleVisibility: .visible) {
            Button(bottle == nil ? "Trust and Install Wine" : "Trust and Update Wine") {
                model.installWine(upgrading: bottle)
            }
            .disabled(unavailable)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This Wine build is unsigned and not notarized by Apple. MagicWine checks the Gcenx download’s checksum, installs its bundled source-built DXMT driver bridge, and removes only this managed Wine bundle’s quarantine to let it run. DXMT is included and needs no additional download. This is not a malware check; system-wide security settings are unchanged."
                 + (bottle == nil
                    ? "\n\nExisting bottles keep their current Wine. Use Update Wine in a bottle’s dashboard to switch it."
                    : "\n\nDownloads Wine if needed, then switches only this bottle to the current managed runtime with MSync support. Its files, settings, and previous Wine installation are kept. If switching fails, the bottle keeps its current Wine."))
        }
    }
}
