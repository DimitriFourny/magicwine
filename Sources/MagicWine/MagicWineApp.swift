import SwiftUI
import MagicWineCore

@main
struct MagicWineApp: App {
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate
    @State private var model = AppModel(paths: ApplicationPaths(
        root: ProcessInfo.processInfo.environment["MAGICWINE_DATA_ROOT"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    ))

    var body: some Scene {
        WindowGroup(id: LibraryView.windowID) {
            LibraryView(model: model)
                .fileImportHost(model)
                .frame(minWidth: 1000, minHeight: 720)
                .task { await model.start() }
        }
        .defaultSize(width: 1440, height: 960)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                NewBottleCommand(model: model)
            }
            CommandMenu("Bottle") {
                BottleCommands(model: model)
            }
        }

        Settings {
            WineSettingsView(model: model)
                .frame(width: 620)
                .padding(24)
                .background(WineTheme.background)
                .fileImportHost(model)
        }

        WindowGroup("Log", id: LogViewerView.windowID, for: URL.self) { $url in
            if let url {
                LogViewerView(url: url)
            }
        }
        .defaultSize(width: 1000, height: 680)

        WindowGroup("Bottle Logs", id: BottleLogsView.windowID, for: UUID.self) { $bottleID in
            if let bottleID {
                BottleLogsView(model: model, bottleID: bottleID)
            }
        }
        .defaultSize(width: 760, height: 480)
    }
}

/// One library window. Selection, the New Bottle sheet, the presented alert, and files opened
/// before the library loaded are this window's state, so several windows do not share them.
private struct LibraryView: View {
    static let windowID = "library"

    let model: AppModel
    @State private var destination: LibraryDestination = .bottles
    @State private var selectedBottleID: UUID?
    @State private var search = ""
    @State private var sheet: LibrarySheet?
    @State private var trashTarget: Bottle?
    @State private var notice: AppNotice?
    @State private var pendingOpenURLs: [URL] = []
    /// Files opened from Finder that wait for the user to choose a bottle, one sheet at a time.
    @State private var openQueue: [OpenedFile] = []
    @State private var followUp: LibrarySheet?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.fileImport) private var fileImport
    @Environment(\.controlActiveState) private var activeState

    private var selectedBottle: Bottle? {
        model.library.bottles.first { $0.id == selectedBottleID }
    }

    /// The sidebar shows the selected bottle only on the Bottles destination; the bottle stays
    /// selected for menu commands and opened installers while another destination is shown.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                if destination == .bottles { return selectedBottleID.map(SidebarItem.bottle) }
                return .destination(destination)
            },
            set: { item in
                switch item {
                case .bottle(let id):
                    selectedBottleID = id
                    destination = .bottles
                case .destination(let target):
                    destination = target
                case nil:
                    break
                }
            }
        )
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebarView(model: model, selection: sidebarSelection, search: search,
                               newBottle: presentNewBottle, trash: { trashTarget = $0 })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(WineTheme.background)
                .toolbar { bottleToolbar }
        }
        .searchable(text: $search, placement: .sidebar, prompt: "Bottles and programs")
        .foregroundStyle(WineTheme.text)
        .tint(WineTheme.accent)
        .buttonStyle(WineButtonStyle())
        .focusedSceneValue(\.selectedBottleID, selectedBottleID)
        .focusedSceneValue(\.fileImport, fileImport)
        .focusedSceneValue(\.newBottle, WindowAction { presentNewBottle() })
        .environment(\.newBottle, WindowAction { presentNewBottle() })
        .onOpenURL { url in
            if model.library.isLoading {
                pendingOpenURLs.append(url)
            } else {
                enqueueOpen(url)
            }
        }
        // Files opened from Finder go to an existing library window instead of a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        .onChange(of: model.library.bottles.map(\.id), initial: true) { _, ids in
            if let selectedBottleID, ids.contains(selectedBottleID) { return }
            selectedBottleID = ids.first
        }
        .onChange(of: model.library.isLoading) { _, loading in
            guard !loading else { return }
            let urls = pendingOpenURLs
            pendingOpenURLs.removeAll()
            for url in urls { enqueueOpen(url) }
        }
        .onChange(of: model.notices.current?.id, initial: true) { claimNotice() }
        .onChange(of: activeState) { claimNotice() }
        .onChange(of: model.activity.logToShow) { _, url in
            guard let url else { return }
            openWindow(id: LogViewerView.windowID, value: url)
            model.activity.logToShow = nil
        }
        .sheet(item: $sheet, onDismiss: sheetDismissed) { sheet in
            switch sheet {
            case .newBottle(let pending):
                NewBottleView(model: model, pending: pending) { bottle in
                    selectedBottleID = bottle.id
                    destination = .bottles
                }
            case .openFile(let file):
                OpenFileSheet(model: model, file: file, preferredBottleID: selectedBottleID) { action in
                    // A sheet cannot present another: the New Bottle sheet follows once this is gone.
                    followUp = .newBottle(PendingOpen(file: file, action: action))
                    self.sheet = nil
                }
            }
        }
        .alert(notice?.title ?? "", isPresented: Binding(
            get: { notice != nil },
            set: { presented in
                guard !presented else { return }
                notice = nil
                // A notice posted while this one was shown is presented next.
                Task { @MainActor in claimNotice() }
            }
        ), presenting: notice) { notice in
            Button("OK", role: .cancel) { }
            if let log = notice.logURL {
                Button("Show Log") { openWindow(id: LogViewerView.windowID, value: log) }
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
                    model.activity.trash(bottle)
                    trashTarget = nil
                }
            }
            Button("Cancel", role: .cancel) { trashTarget = nil }
        } message: {
            Text("This moves the bottle and its Windows files to macOS Trash. Programs outside the bottle are not deleted. Stop all Windows processes in the bottle first.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .bottles:
            if let bottle = selectedBottle {
                BottleDashboardView(model: model, bottle: bottle, programFilter: search,
                                    trash: { trashTarget = bottle })
                    .id(bottle.id)
            } else {
                WelcomeView(model: model, newBottle: presentNewBottle)
            }
        case .gamepads:
            GamepadView(paths: model.paths)
        case .downloads:
            downloads
        case .documentation:
            documentation
        }
    }

    /// The selected bottle's main actions, enabled by the same predicates as its dashboard.
    @ToolbarContentBuilder
    private var bottleToolbar: some ToolbarContent {
        if destination == .bottles, let bottle = selectedBottle {
            let state = model.activity.activity(for: bottle)
            ToolbarItemGroup(placement: .primaryAction) {
                Button { fileImport?(.installer(bottle)) } label: {
                    Label("Install EXE/MSI", systemImage: "square.and.arrow.down")
                }
                .disabled(!bottle.isInitialized || state.blocksPrefixMutation || fileImport == nil)
                .help("Run a Windows EXE or MSI installer in this bottle")
                Button { fileImport?(.program(bottle)) } label: {
                    Label("Add Program", systemImage: "app.badge")
                }
                .disabled(!bottle.isInitialized || state.blocksLibraryEdit || fileImport == nil)
                .help("Register an existing EXE, LNK, or URL shortcut without moving its file")
                Button { model.activity.refreshPrograms(in: bottle) } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!bottle.isInitialized || state.blocksLibraryEdit)
                .help("Find Windows Start Menu and Desktop shortcuts, including Steam URL shortcuts")
                Button { model.activity.stop(bottle) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .disabled(!state.allowsStop(of: bottle))
                .help("Stop all Windows processes in this bottle")
            }
        }
    }

    /// Only the frontmost window presents the app-wide alert; it waits while none is.
    private func claimNotice() {
        guard notice == nil, activeState == .key, let pending = model.notices.current else { return }
        notice = pending
        model.notices.current = nil
    }

    private func presentNewBottle() {
        guard sheet == nil else { return }
        sheet = .newBottle(nil)
    }

    /// Holding Option while opening an EXE chooses Add as Program over Run Installer first.
    private func enqueueOpen(_ url: URL) {
        guard let file = model.openedFile(url, preferringProgram: NSEvent.modifierFlags.contains(.option)) else { return }
        openQueue.append(file)
        presentNextOpen()
    }

    private func presentNextOpen() {
        guard sheet == nil, !openQueue.isEmpty else { return }
        sheet = .openFile(openQueue.removeFirst())
    }

    /// After a sheet closes: the sheet it asked for, else the next opened file.
    private func sheetDismissed() {
        if let next = followUp {
            followUp = nil
            sheet = next
        } else {
            presentNextOpen()
        }
    }

    private var downloads: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Downloads").font(WineTheme.Font.display)
                Text("Install Wine for new bottles. To update an existing bottle, use Update Wine in its dashboard.")
                    .foregroundStyle(WineTheme.muted)
                WineCard(title: "Wine Runtime", icon: "arrow.down.to.line") {
                    RuntimeSetupView(model: model)
                }
                if !model.runtimes.runtimes.isEmpty {
                    WineCard(title: "Available Runtimes", icon: "wineglass", trailing: localized("\(model.runtimes.runtimes.count) installed")) {
                        ForEach(model.runtimes.runtimes) { runtime in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(runtime.version).font(.headline)
                                Text(runtime.executableURL.path)
                                    .font(.caption).foregroundStyle(WineTheme.muted)
                                    .textSelection(.enabled)
                            }
                            if runtime.id != model.runtimes.runtimes.last?.id { Divider() }
                        }
                    }
                }
                WineCard(title: "Storage", icon: "internaldrive",
                         trailing: model.storage.plan.map { ByteCountFormatter.string(fromByteCount: $0.totalSize, countStyle: .file) + " unused" }) {
                    StorageCleanupView(model: model)
                }
            }
            .padding(24).frame(maxWidth: 850, alignment: .leading)
        }
    }

    private var documentation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("A little bottled knowledge.").font(WineTheme.Font.display)
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
                    Button("Reveal Logs") { Finder.revealLibraryLogs(paths: model.paths) }
                }
            }
            .padding(24).frame(maxWidth: 850, alignment: .leading)
        }
    }
}

private struct WelcomeView: View {
    let model: AppModel
    let newBottle: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 24) {
                    Image(nsImage: WineArtwork.bottle)
                        .resizable().scaledToFit().frame(width: 120, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Welcome to MagicWine").font(WineTheme.Font.display)
                        Text("Your Windows world, bottled.")
                            .foregroundStyle(WineTheme.muted)
                    }
                }
                Text("A bottle keeps a Windows environment, its programs, and its Wine version together.")
                    .foregroundStyle(WineTheme.muted)
                if model.library.isLoading {
                    ProgressView("Loading your library…")
                } else if model.runtimes.preferredRuntime == nil {
                    WineCard(title: "Set Up Wine", icon: "wineglass") {
                        Text("Install Wine, then create your first bottle.")
                            .foregroundStyle(WineTheme.muted)
                        RuntimeSetupView(model: model)
                    }
                } else {
                    Button("Create Bottle…", action: newBottle)
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

/// The one sheet a library window presents: its sheets never overlap.
private enum LibrarySheet: Identifiable {
    case newBottle(PendingOpen?)
    case openFile(OpenedFile)

    var id: String {
        switch self {
        case .newBottle: "new-bottle"
        case .openFile(let file): file.id.uuidString
        }
    }
}

private struct NewBottleView: View {
    let model: AppModel
    /// A file the user opened that runs in this bottle once its setup finishes.
    let pending: PendingOpen?
    /// Called with the created bottle, before its setup finishes.
    let created: (Bottle) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var runtimeID = ""

    private var runtime: RuntimeDescriptor? {
        model.runtimes.runtimes.first { $0.id == runtimeID } ?? model.runtimes.preferredRuntime
    }
    private var validName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 80
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Bottle").font(.title2)
            if let pending {
                Text(pending.action == .install
                     ? localized("When setup finishes, \(pending.file.url.lastPathComponent) will run its installer in this bottle.")
                     : localized("When setup finishes, \(pending.file.url.lastPathComponent) will be added to this bottle."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if runtime == nil {
                Text("Install Wine before creating a bottle.")
                RuntimeSetupView(model: model)
            }
            if !model.runtimes.runtimes.isEmpty {
                TextField("Bottle name", text: $name).textFieldStyle(.roundedBorder)
                    .onSubmit { create() }
                    .disabled(model.library.isCreating)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Wine runtime", selection: $runtimeID) {
                            Text("Use preferred Wine").tag("")
                            ForEach(model.runtimes.runtimes) { runtime in
                                Text("\(runtime.version) — \(runtime.executableURL.deletingLastPathComponent().path)")
                                    .tag(runtime.id)
                            }
                        }
                        .disabled(model.library.isCreating || model.runtimes.activity != nil)
                        if let runtime {
                            Text(runtime.executableURL.path).font(.caption).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 8)
                }
                if model.library.isCreating { ProgressView("Creating bottle…") }
            }
            if let error = model.library.creationError {
                Text(error).foregroundStyle(WineTheme.danger).textSelection(.enabled)
                Button("Reveal Logs") { Finder.revealLibraryLogs(paths: model.paths) }
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.library.isCreating)
                Spacer()
                Button("Create Bottle", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!validName || runtime == nil || model.library.isCreating || model.runtimes.activity != nil)
            }
        }
        .padding(24).frame(width: 550)
        .interactiveDismissDisabled(model.library.isCreating)
    }

    private func create() {
        guard validName, !model.library.isCreating, model.runtimes.activity == nil, let runtime else { return }
        Task {
            guard let bottle = await model.createBottle(name: name, runtime: runtime, then: pending) else { return }
            created(bottle)
            dismiss()
        }
    }
}

private struct WineSettingsView: View {
    let model: AppModel
    @Environment(\.fileImport) private var fileImport

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Wine Runtime").font(.title2)
                RuntimeSetupView(model: model)
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 12) {
                        if !model.runtimes.runtimes.isEmpty {
                            Picker("Preferred Wine", selection: Binding(
                                get: { model.runtimes.preferredRuntime?.id ?? "" },
                                set: { model.runtimes.prefer(id: $0) }
                            )) {
                                if model.runtimes.preferredRuntime == nil {
                                    Text("No preferred Wine — install or choose one").tag("")
                                }
                                ForEach(model.runtimes.runtimes) { runtime in
                                    Text("\(runtime.version) — \(runtime.executableURL.path)").tag(runtime.id)
                                }
                            }
                            .disabled(model.runtimes.activity != nil)
                        }
                        Button("Choose Wine Executable…") { fileImport?(.wineExecutable) }
                            .disabled(model.runtimes.activity != nil || fileImport == nil)
                        Text("Use a custom runtime for compatibility needs, including D3DMetal. New bottles use your preferred Wine unless you override it.")
                            .font(.callout).foregroundStyle(.secondary)
                        if let path = model.runtimes.settings.customWinePath {
                            Text("Saved custom executable: \(path)").font(.caption).textSelection(.enabled)
                        }
                        HStack {
                            Button("Find Installed Wine") { model.runtimes.refresh() }
                                .disabled(model.runtimes.activity != nil)
                            Button("Reveal Logs") { Finder.revealLibraryLogs(paths: model.paths) }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
    }
}

private struct RuntimeSetupView: View {
    let model: AppModel

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
    let model: AppModel
    var bottle: Bottle? = nil
    @State private var showsTrustConfirmation = false

    private var unavailable: Bool {
        if model.library.isLoading || model.runtimes.activity != nil { return true }
        guard let bottle else { return false }
        return model.activity.activity(for: bottle).blocksPrefixMutation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(bottle == nil ? localized("Install / Update Wine…") : localized("Update Wine…")) {
                showsTrustConfirmation = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(unavailable)
            if case let .downloading(progress) = model.runtimes.installationProgress {
                WineDownloadProgressView(progress: progress)
            } else if let activity = model.runtimes.activity {
                ProgressView(activity)
                    .controlSize(.small)
            }
            if let error = model.runtimes.error {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Wine Setup Failed", systemImage: "exclamationmark.triangle").font(.headline)
                    Text(error).textSelection(.enabled)
                    Button("Reveal Logs") { Finder.revealLibraryLogs(paths: model.paths) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .confirmationDialog(bottle.map { localized("Update Wine for \($0.name)?") } ?? localized("Trust Wine?"),
                            isPresented: $showsTrustConfirmation, titleVisibility: .visible) {
            Button(bottle == nil ? localized("Trust and Install Wine") : localized("Trust and Update Wine")) {
                model.runtimes.installWine(upgrading: bottle)
            }
            .disabled(unavailable)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(localized("This Wine build is unsigned and not notarized by Apple. MagicWine checks the Gcenx download’s checksum, installs its bundled source-built DXMT driver bridge, and removes only this managed Wine bundle’s quarantine to let it run. DXMT is included and needs no additional download. This is not a malware check; system-wide security settings are unchanged.")
                 + "\n\n" + (bottle == nil
                    ? localized("Existing bottles keep their current Wine. Use Update Wine in a bottle’s dashboard to switch it.")
                    : localized("Downloads Wine if needed, then switches only this bottle to the current managed runtime with MSync support. Its files, settings, and previous Wine installation are kept. If switching fails, the bottle keeps its current Wine.")))
        }
    }
}
