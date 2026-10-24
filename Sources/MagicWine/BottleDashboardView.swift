import AppKit
import SwiftUI
import MagicWineCore

struct BottleDashboardView: View {
    let model: AppModel
    let bottle: Bottle
    /// The window's search text; programs whose names match are listed.
    let programFilter: String
    let trash: () -> Void
    @State private var editingProgram: WindowsProgram?
    @State private var diagnosticProgram: WindowsProgram?
    /// Target of Bottle › Launch; clicking a program row selects it.
    @State private var selectedProgramID: UUID?
    @AppStorage("programSort") private var programSort: ProgramSort = .name
    @Environment(\.openWindow) private var openWindow
    @Environment(\.fileImport) private var fileImport
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsDependencies = false
    /// A drag is over the dashboard (EXE/MSI installers) or over its program list (EXE/LNK/URL).
    @State private var installTargeted = false
    @State private var programsTargeted = false

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
        .fileDrop(isEnabled: !prefixOperationUnavailable, targeted: $installTargeted) { model.install(dropped: $0, in: currentBottle) }
        .dropHighlight(installTargeted && !programsTargeted, cornerRadius: 0, caption: "Drop to install in \(currentBottle.name)")
        .navigationTitle(currentBottle.name)
        .focusedSceneValue(\.selectedProgramID, selectedProgramID)
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
                    Text(currentBottle.name).font(WineTheme.Font.title)
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
                        .opacity(WineTheme.artworkOpacity(colorScheme, dark: 0.65))
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
            Label("Bottle Settings", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(WineButtonStyle())
        .help("Show this bottle’s runtime, graphics, and compatibility settings")

        if showsStop {
            Button { model.activity.stop(currentBottle) } label: {
                Label(activity.isStopping ? localized("Stopping…") : localized("Stop"), systemImage: "stop.fill")
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
                Text(activity.isStopping ? localized("Stopping Windows processes…") : (activity.title ?? localized("Working…")))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .padding(.horizontal, 4)
        }
        if activity.hasRunningPrograms, activity.title == nil, !activity.isStopping {
            VStack(alignment: .leading, spacing: 8) {
                Label("Running: \(activity.runningProgramNames.joined(separator: ", ")). Launch again to reopen a background app. Use its Exit command to quit; Stop ends all programs in this bottle.",
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
            WineCard(title: LocalizedStringKey(notice.title), icon: "info.circle") {
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

    private func informationRow(_ title: LocalizedStringKey, value: String, monospaced: Bool = false) -> some View {
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

    /// Programs matching the window's search, favorites first, then in the chosen order.
    private var visiblePrograms: [WindowsProgram] {
        let programs = programFilter.isEmpty ? currentBottle.programs
            : currentBottle.programs.filter { $0.name.localizedStandardContains(programFilter) }
        return programSort.sorted(programs)
    }

    private var installedPrograms: some View {
        WineCard(title: "Installed Programs", icon: "square.grid.2x2", trailing: localized("\(currentBottle.programs.count) items")) {
            let programs = visiblePrograms
            if currentBottle.programs.count > 1 {
                Picker("Sort programs", selection: $programSort) {
                    ForEach(ProgramSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Favorites stay first")
            }
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
            } else if programs.isEmpty {
                Text("No programs in this bottle match “\(programFilter)”.")
                    .font(.callout)
                    .foregroundStyle(WineTheme.muted)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(programs) { program in
                        if program.id != programs.first?.id { rowSeparator }
                        programRow(program)
                    }
                }
            }
        }
        .fileDrop(isEnabled: !libraryEditUnavailable, targeted: $programsTargeted) { model.addPrograms(dropped: $0, to: currentBottle) }
        .dropHighlight(programsTargeted, caption: "Drop to add programs to \(currentBottle.name)")
    }

    private func programRow(_ program: WindowsProgram) -> some View {
        HStack(spacing: 12) {
            WindowsProgramIconView(
                executablePath: program.executablePath,
                prefix: bottleURL.appendingPathComponent("prefix", isDirectory: true),
                revision: model.library.iconRevision(for: currentBottle.id)
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(program.name)
                        .font(.system(.callout, weight: .semibold))
                        .lineLimit(1)
                        .help(program.name)
                    if activity.isRunning(program) {
                        Text("Running").font(WineTheme.Font.small.weight(.medium))
                            .foregroundStyle(WineTheme.success)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(WineTheme.success.opacity(0.12), in: Capsule())
                    }
                }
                Text(displayPath(program.executablePath)).font(WineTheme.Font.callout)
                    .foregroundStyle(WineTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(program.executablePath)
                Text(ProgramHistory.summary(of: program)).font(WineTheme.Font.small)
                    .foregroundStyle(WineTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button { model.bottleSettings.setFavorite(!program.isFavorite, for: program, in: currentBottle) } label: {
                Image(systemName: program.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(program.isFavorite ? WineTheme.favorite : WineTheme.muted)
            }
            .buttonStyle(.borderless)
            .disabled(activity.blocksLibraryEdit)
            .accessibilityLabel(program.isFavorite ? localized("Remove \(program.name) from Favorites") : localized("Add \(program.name) to Favorites"))
            .help(program.isFavorite ? localized("Remove from Favorites") : localized("Add to Favorites; favorites are listed first"))
            Button { model.activity.launch(program, in: currentBottle) } label: {
                Text("Launch").font(WineTheme.Font.label)
                    .frame(minWidth: 64, minHeight: 28)
            }
            .buttonStyle(WineButtonStyle(prominent: true))
            .disabled(launchUnavailable)
            .accessibilityLabel("Launch \(program.name)")
            Menu {
                Button("Edit…") { editingProgram = program }
                favoriteButton(program)
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
        .padding(.horizontal, 6)
        .background(selectedProgramID == program.id ? WineTheme.accent.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture { selectedProgramID = program.id }
        .accessibilityAddTraits(selectedProgramID == program.id ? .isSelected : [])
        .contextMenu {
            Button("Launch") { model.activity.launch(program, in: currentBottle) }
                .disabled(launchUnavailable)
            Button("Launch with Diagnostics…") { diagnosticProgram = program }
                .disabled(launchUnavailable)
            Button("Edit…") { editingProgram = program }
                .disabled(activity.blocksLibraryEdit)
            runningLogButton(program)
            favoriteButton(program)
                .disabled(activity.blocksLibraryEdit)
            Button("Remove from MagicWine", role: .destructive) {
                model.activity.removeProgram(program, in: currentBottle)
            }
            .disabled(activity.blocksLibraryEdit)
        }
    }

    private func favoriteButton(_ program: WindowsProgram) -> some View {
        Button(program.isFavorite ? localized("Remove from Favorites") : localized("Add to Favorites")) {
            model.bottleSettings.setFavorite(!program.isFavorite, for: program, in: currentBottle)
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

    private func toolButton(_ title: LocalizedStringKey, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Label(title, systemImage: icon).font(WineTheme.Font.callout)
                .foregroundStyle(destructive ? WineTheme.danger : WineTheme.text)
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

/// The dashboard's program order; favorites always come first.
enum ProgramSort: String, CaseIterable {
    case name
    case recent

    var title: String {
        switch self {
        case .name: localized("Name")
        case .recent: localized("Recent")
        }
    }

    /// Recent puts the latest launch first and never-launched programs last, by name.
    func sorted(_ programs: [WindowsProgram]) -> [WindowsProgram] {
        programs.sorted { left, right in
            if left.isFavorite != right.isFavorite { return left.isFavorite }
            if self == .recent, left.lastLaunchedAt != right.lastLaunchedAt {
                return (left.lastLaunchedAt ?? .distantPast) > (right.lastLaunchedAt ?? .distantPast)
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}
