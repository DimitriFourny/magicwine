import AppKit
import SwiftUI
import MagicWineCore

struct BottleDashboardView: View {
    let model: AppModel
    let bottle: Bottle
    let trash: () -> Void
    @State private var editingProgram: WindowsProgram?
    @State private var diagnosticProgram: WindowsProgram?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.fileImport) private var fileImport
    @State private var showsDependencies = false

    private var currentBottle: Bottle {
        model.library.current(bottle)
    }

    private var activity: BottleActivity { model.activity.activity(for: currentBottle) }
    private var prefixLocked: Bool { activity.blocksPrefixMutation }
    private var prefixOperationUnavailable: Bool { prefixLocked || !currentBottle.isInitialized }
    private var libraryEditUnavailable: Bool { activity.blocksLibraryEdit || !currentBottle.isInitialized }
    private var launchUnavailable: Bool { activity.blocksLaunch || !currentBottle.isInitialized }
    private var bottleURL: URL {
        model.library.bottleURL(for: currentBottle)
    }
    private var showsStop: Bool {
        activity.canStop || activity.hasRunningPrograms || activity.isStopping
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 32)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header {
                            withAnimation { proxy.scrollTo("runtime", anchor: .top) }
                        }
                        operationFeedback
                        if contentWidth >= 900 {
                            HStack(alignment: .top, spacing: 14) {
                                programsColumn
                                    .frame(width: (contentWidth - 14) * 0.56)
                                secondaryColumn
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            programsColumn
                            secondaryColumn
                        }
                    }
                    .frame(width: contentWidth, alignment: .leading)
                    .padding(16)
                }
            }
            .background(WineTheme.background)
        }
        .foregroundStyle(WineTheme.text)
        .navigationTitle(currentBottle.name)
        .sheet(item: $editingProgram) { program in
            ProgramEditorView(model: model, bottle: currentBottle, program: program)
        }
        .sheet(isPresented: $showsDependencies) {
            DependenciesView(model: model, bottle: currentBottle)
        }
        .alert("Launch \(diagnosticProgram?.name ?? "") with Diagnostics?", isPresented: Binding(
            get: { diagnosticProgram != nil },
            set: { if !$0 { diagnosticProgram = nil } }
        ), presenting: diagnosticProgram) { program in
            Button("Launch with Diagnostics") { model.activity.launch(program, in: currentBottle, diagnostics: true) }
                .disabled(launchUnavailable)
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text("This launch only adds Wine diagnostics (WINEDEBUG=\(WineRuntime.diagnosticWineDebug)): DLL load decisions, exceptions, and process starts. The program may start more slowly and its log can grow large. Nothing is saved; when the program ends, its log is offered here.")
        }
    }

    private var programsColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            installedPrograms
            WineCard(title: "Tools", icon: "wrench.and.screwdriver") {
                tools
            }
        }
    }

    private var secondaryColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            performanceAndRuntime
            bottleInformation
        }
    }

    private func header(onSettings: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(nsImage: WineArtwork.bottle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(currentBottle.name)
                        .font(.system(size: 26, weight: .medium, design: .serif))
                        .lineLimit(1)
                        .help(currentBottle.name)
                        .accessibilityAddTraits(.isHeader)
                    Text("\(currentBottle.runtime.version) · \(currentBottle.graphics.backend.displayName)")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("Wine executable: \(currentBottle.runtime.executableURL.path)")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                WineStatus(model: model, bottle: currentBottle)
                    .fixedSize()
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    installerActions
                    Spacer(minLength: 8)
                    settingsActions(onSettings: onSettings)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) { installerActions }
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        settingsActions(onSettings: onSettings)
                    }
                }
            }
        }
        .padding(14)
        .background {
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    WineTheme.panel
                    Image(nsImage: WineArtwork.cellar)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width * 0.6, height: geometry.size.height)
                        .clipped()
                        .mask {
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.45), .black],
                                startPoint: .leading, endPoint: .trailing
                            )
                        }
                        .opacity(0.65)
                        .accessibilityHidden(true)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(WineTheme.border)
        }
    }

    @ViewBuilder
    private var installerActions: some View {
        Button { fileImport?(.installer(currentBottle)) } label: {
            Label("Install EXE/MSI", systemImage: "plus")
        }
        .buttonStyle(WineButtonStyle(prominent: true))
        .disabled(prefixOperationUnavailable)
        .help("Run a Windows EXE or MSI installer in this bottle")

        Button { fileImport?(.program(currentBottle)) } label: {
            Label("Add Program", systemImage: "app.badge")
        }
        .buttonStyle(WineButtonStyle())
        .disabled(libraryEditUnavailable)
        .help("Register an existing EXE, LNK, or URL shortcut without moving its file")

        Button { model.activity.refreshPrograms(in: currentBottle) } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(WineButtonStyle())
        .disabled(libraryEditUnavailable)
        .help("Find Windows Start Menu and Desktop shortcuts, including Steam URL shortcuts")
    }

    @ViewBuilder
    private func settingsActions(onSettings: @escaping () -> Void) -> some View {
        Button(action: onSettings) {
            Label("Settings", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(WineButtonStyle())
        .help("Show runtime and graphics settings")

        if showsStop {
            Button { model.activity.stop(currentBottle) } label: {
                Label(activity.isStopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
            }
            .buttonStyle(WineButtonStyle())
            .disabled(activity.isStopping || activity.graphicsSetupID != nil)
            .help("Stop all Windows processes in this bottle")
        }
    }

    @ViewBuilder
    private var operationFeedback: some View {
        if activity.graphicsProgress == nil, activity.title != nil || activity.isStopping {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(activity.isStopping ? "Stopping Windows processes…" : (activity.title ?? "Working…"))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 4)
        }
        if activity.hasRunningPrograms, activity.title == nil, !activity.isStopping {
            VStack(alignment: .leading, spacing: 8) {
                Label("Windows programs are running. Launch again to reopen a background app. Use its Exit command to quit; Stop ends all programs in this bottle.",
                      systemImage: "play.circle")
                    .font(.callout)
                    .foregroundStyle(WineTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                let live = model.activity.liveLogs(for: currentBottle)
                if !live.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(live) { log in
                            Button("Show Log: \(log.programName)") { showLog(log.url) }
                                .help("Follow the output of this running launch")
                        }
                    }
                    .buttonStyle(WineButtonStyle())
                }
            }
            .padding(.horizontal, 4)
        }

        if let error = activity.error {
            OperationErrorCard(model: model, bottle: currentBottle, error: error)
        }

        ForEach(activity.notices) { notice in
            WineCard(title: notice.title, icon: "info.circle") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(notice.message)
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 9) {
                        Button("Show Log") { showLog(notice.logURL) }
                        Button("Dismiss") { model.activity.dismissNotice(notice.id, for: currentBottle) }
                    }
                    .buttonStyle(WineButtonStyle())
                }
            }
        }

        if !currentBottle.isInitialized {
            WineCard(title: "Finish Bottle Setup", icon: "shippingbox") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("This bottle needs setup before you can run programs. If setup fails, it stays here so you can resolve the error and retry.")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Retry Setup") { model.activity.initialize(currentBottle) }
                        .buttonStyle(WineButtonStyle(prominent: true))
                        .disabled(prefixLocked)
                }
            }
        }
    }

    private var bottleInformation: some View {
        WineCard(title: "Bottle Details", icon: "shippingbox") {
            VStack(spacing: 0) {
                informationRow("Name", value: currentBottle.name)
                rowSeparator
                informationRow("Created", value: currentBottle.createdAt.formatted(date: .abbreviated, time: .shortened))
                rowSeparator
                HStack(spacing: 8) {
                    Text("Path").foregroundStyle(WineTheme.muted)
                    Text(bottleURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .textSelection(.enabled)
                        .help(bottleURL.path)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(bottleURL.path, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy bottle path")
                    .help("Copy bottle path")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([bottleURL])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Reveal bottle in Finder")
                    .help("Reveal bottle in Finder")
                }
                .font(.callout)
                .buttonStyle(.borderless)
                .padding(.vertical, 9)
                rowSeparator
                HStack {
                    Text("Status").foregroundStyle(WineTheme.muted)
                    Spacer(minLength: 12)
                    WineStatus(model: model, bottle: currentBottle)
                }
                .font(.callout)
                .padding(.vertical, 9)
            }
            DisclosureGroup("Advanced Details") {
                VStack(alignment: .leading, spacing: 12) {
                    informationRow("Bottle ID", value: currentBottle.id.uuidString, monospaced: true)
                    informationRow("Wine path", value: currentBottle.runtime.executableURL.path, monospaced: true)
                }
                .padding(.top, 8)
            }
            .font(.callout)
        }
    }

    private func informationRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(WineTheme.muted)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(value)
        }
        .font(.callout)
        .padding(.vertical, 9)
    }

    private var installedPrograms: some View {
        WineCard(title: "Installed Programs", icon: "square.grid.2x2", trailing: "\(currentBottle.programs.count) items") {
            if currentBottle.programs.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("No programs yet", systemImage: "app.dashed")
                        .font(.headline)
                    Text("Use Install EXE/MSI or Add Program above to get started. Refresh finds Start Menu and Desktop shortcuts, including Steam URL shortcuts.")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(currentBottle.programs) { program in
                        if program.id != currentBottle.programs.first?.id { rowSeparator }
                        programRow(program)
                    }
                }
            }
        }
    }

    private func programRow(_ program: WindowsProgram) -> some View {
        HStack(spacing: 12) {
            WindowsProgramIconView(
                executablePath: program.executablePath,
                prefix: bottleURL.appendingPathComponent("prefix", isDirectory: true),
                revision: model.library.iconRevision(for: currentBottle.id)
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(program.name)
                    .font(.system(.callout, weight: .semibold))
                    .lineLimit(1)
                    .help(program.name)
                Text(displayPath(program.executablePath))
                    .font(.system(size: 12))
                    .foregroundStyle(WineTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(program.executablePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { model.activity.launch(program, in: currentBottle) } label: {
                Text("Launch")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 64, minHeight: 28)
            }
            .buttonStyle(WineButtonStyle(prominent: true))
            .disabled(launchUnavailable)
            .accessibilityLabel("Launch \(program.name)")
            Menu {
                Button("Edit…") { editingProgram = program }
                Button("Launch with Diagnostics…") { diagnosticProgram = program }
                    .disabled(launchUnavailable)
                runningLogButton(program)
                Button("Remove from MagicWine", role: .destructive) {
                    model.activity.removeProgram(program, in: currentBottle)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(activity.blocksLibraryEdit)
            .accessibilityLabel("Actions for \(program.name)")
            .help("Edit this program’s launch options, or remove it from MagicWine without deleting its file")
        }
        .padding(.vertical, 10)
        .contextMenu {
            Button("Launch") { model.activity.launch(program, in: currentBottle) }
                .disabled(launchUnavailable)
            Button("Launch with Diagnostics…") { diagnosticProgram = program }
                .disabled(launchUnavailable)
            Button("Edit…") { editingProgram = program }
                .disabled(activity.blocksLibraryEdit)
            runningLogButton(program)
            Button("Remove from MagicWine", role: .destructive) {
                model.activity.removeProgram(program, in: currentBottle)
            }
            .disabled(activity.blocksLibraryEdit)
        }
    }

    private func displayPath(_ path: String) -> String {
        let prefix = bottleURL.appendingPathComponent("prefix", isDirectory: true).path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private var performanceAndRuntime: some View {
        WineCard(title: "Runtime", icon: "speedometer") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Label("Wine version", systemImage: "wineglass")
                        .font(.callout).foregroundStyle(WineTheme.muted)
                    Spacer(minLength: 0)
                    Text(currentBottle.runtime.version)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(currentBottle.runtime.executableURL.path)
                }
                rowSeparator
                GraphicsSettingsView(model: model, bottle: currentBottle)
                Button { model.activity.configure(currentBottle) } label: {
                    Label("Configure Runtime", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(WineButtonStyle())
                .disabled(prefixOperationUnavailable)
                .help("Open this bottle’s Wine configuration dialog")
                if let componentID = currentBottle.graphics.componentID {
                    DisclosureGroup("Component Details") {
                        Text(componentID)
                            .font(.callout)
                            .foregroundStyle(WineTheme.muted)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                    .font(.callout)
                }
            }
        }
        .id("runtime")
    }

    private var tools: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                toolButton("Reveal C: Drive", icon: "internaldrive") { Finder.reveal(model.library.driveURL(for: currentBottle)) }
                    .disabled(!currentBottle.isInitialized)
                    .help("Reveal this bottle’s Windows drive in Finder")
                toolButton("Logs…", icon: "doc.text") { showLogs() }
                    .help("List this bottle’s logs and open them in the log viewer")
            }
            toolButton("Dependencies…", icon: "puzzlepiece.extension") { showsDependencies = true }
                .disabled(!currentBottle.isInitialized)
                .help("Install Visual C++ runtimes, D3DCompiler 47 or Microsoft core fonts into this bottle")
            rowSeparator
            toolButton("Trash Bottle…", icon: "trash", destructive: true, action: trash)
                .disabled(prefixLocked)
                .help("Ask for confirmation before moving this bottle to Trash")
        }
    }

    private func toolButton(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(destructive ? Color(red: 1, green: 0.42, blue: 0.56) : WineTheme.text)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(WineButtonStyle())
    }

    /// The newest running launch of `program`, if any.
    @ViewBuilder
    private func runningLogButton(_ program: WindowsProgram) -> some View {
        if let log = model.activity.liveLogs(for: currentBottle).last(where: { $0.programID == program.id }) {
            Button("Show Running Log") { showLog(log.url) }
        }
    }

    private func showLog(_ url: URL) { openWindow(id: LogViewerView.windowID, value: url) }

    private func showLogs() { openWindow(id: BottleLogsView.windowID, value: currentBottle.id) }

    private var rowSeparator: some View {
        Rectangle()
            .fill(WineTheme.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
