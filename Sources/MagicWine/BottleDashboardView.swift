import AppKit
import SwiftUI
import MagicWineCore

struct BottleDashboardView: View {
    @ObservedObject var model: AppModel
    let bottle: Bottle
    let trash: () -> Void

    private var currentBottle: Bottle {
        model.bottles.first { $0.id == bottle.id } ?? bottle
    }

    private var activity: BottleActivity { model.activity(for: currentBottle) }
    private var busy: Bool { activity.title != nil || activity.hasRunningPrograms || activity.isStopping }
    private var operationUnavailable: Bool { busy || !currentBottle.isInitialized }
    private var launchUnavailable: Bool { activity.title != nil || activity.isStopping || !currentBottle.isInitialized }
    private var bottleURL: URL {
        model.paths.bottlesDirectory.appendingPathComponent(currentBottle.id.uuidString, isDirectory: true)
    }
    private var stopUnavailable: Bool {
        activity.isStopping || activity.graphicsSetupID != nil
            || (!activity.canStop && (activity.title != nil || !currentBottle.isInitialized))
    }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = max(0, geometry.size.width - 40)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    hero
                    operationFeedback
                    if contentWidth >= 900 {
                        HStack(alignment: .top, spacing: 18) {
                            leftColumn
                                .frame(width: (contentWidth - 18) * 0.54)
                            rightColumn
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        leftColumn
                        rightColumn
                    }
                }
                .frame(width: contentWidth, alignment: .leading)
                .padding(20)
            }
            .background(WineTheme.background)
        }
        .foregroundStyle(WineTheme.text)
        .navigationTitle(currentBottle.name)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 24) {
                Image(nsImage: WineArtwork.bottle)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 144, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 9) {
                    Text(currentBottle.name)
                        .font(.system(size: 38, weight: .regular, design: .serif))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your Windows world, bottled.")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 14) {
                            runtimeLabel
                            WineStatus(model: model, bottle: currentBottle)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            runtimeLabel
                            WineStatus(model: model, bottle: currentBottle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 9) {
                    installerActions
                    Spacer(minLength: 12)
                    settingsActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 9) { installerActions }
                    HStack(spacing: 9) { settingsActions }
                }
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        }
                        .opacity(0.65)
                        .accessibilityHidden(true)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(WineTheme.border, lineWidth: 1)
        }
    }

    private var runtimeLabel: some View {
        Label(currentBottle.runtime.version, systemImage: "shippingbox")
            .font(.caption)
            .foregroundStyle(WineTheme.muted)
            .lineLimit(2)
            .help("Wine executable: \(currentBottle.runtime.executableURL.path)")
    }

    @ViewBuilder
    private var installerActions: some View {
        Button { model.chooseInstaller(in: currentBottle) } label: {
            Label("Install EXE/MSI", systemImage: "plus")
        }
        .buttonStyle(WineButtonStyle(prominent: true))
        .disabled(operationUnavailable)
        .help("Run a Windows EXE or MSI installer in this bottle")

        Button { model.chooseProgram(in: currentBottle) } label: {
            Label("Add Program", systemImage: "app.badge")
        }
        .buttonStyle(WineButtonStyle())
        .disabled(operationUnavailable)
        .help("Register an existing EXE, LNK, or URL shortcut without moving its file")

        Button { model.refreshPrograms(in: currentBottle) } label: {
            Label("Refresh Shortcuts", systemImage: "arrow.clockwise")
        }
        .buttonStyle(WineButtonStyle())
        .disabled(operationUnavailable)
        .help("Find Windows Start Menu and Desktop shortcuts, including Steam URL shortcuts")
    }

    @ViewBuilder
    private var settingsActions: some View {
        Button { model.configure(currentBottle) } label: {
            Label("Bottle Settings", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(WineButtonStyle())
        .disabled(operationUnavailable)
        .help("Open Wine configuration for this bottle")

        Button { model.stop(currentBottle) } label: {
            Label(activity.isStopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
        }
        .buttonStyle(WineButtonStyle())
        .disabled(stopUnavailable)
        .help("Stop all Windows processes in this bottle")
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
            Label("Windows programs are running. Launch again to reopen a background app. Use its Exit command to quit; Stop ends all programs in this bottle.",
                  systemImage: "play.circle")
                .font(.callout)
                .foregroundStyle(WineTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }

        if let error = activity.error {
            WineCard(title: "Operation Failed", icon: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(error)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    HStack(spacing: 9) {
                        Button("Reveal Logs") { model.revealLogs(for: currentBottle) }
                        Button("Dismiss") { model.dismissError(for: currentBottle) }
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
                    Button("Retry Setup") { model.initialize(currentBottle) }
                        .buttonStyle(WineButtonStyle(prominent: true))
                        .disabled(busy)
                }
            }
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            bottleInformation
            installedPrograms
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            quickActions
            performanceAndRuntime
            tools
        }
    }

    private var bottleInformation: some View {
        WineCard(title: "Bottle Information", icon: "info.circle") {
            VStack(spacing: 0) {
                informationRow("Name", value: currentBottle.name)
                rowSeparator
                informationRow("Wine version", value: currentBottle.runtime.version)
                rowSeparator
                informationRow("Path", value: bottleURL.path, monospaced: true)
                rowSeparator
                informationRow("Created", value: currentBottle.createdAt.formatted(date: .abbreviated, time: .shortened))
                rowSeparator
                HStack(alignment: .top) {
                    Text("Status")
                        .foregroundStyle(WineTheme.muted)
                    Spacer(minLength: 12)
                    WineStatus(model: model, bottle: currentBottle)
                }
                .font(.callout)
                .padding(.vertical, 9)
            }
        }
    }

    private func informationRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundStyle(WineTheme.muted)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
                .lineLimit(monospaced ? 3 : 2)
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
                    Text("Install an EXE or MSI, or add an existing Windows program. Refresh Shortcuts finds Start Menu and Desktop shortcuts, including Steam URL shortcuts.")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Install Your First Program") { model.chooseInstaller(in: currentBottle) }
                        .buttonStyle(WineButtonStyle(prominent: true))
                        .disabled(operationUnavailable)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
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
                revision: model.programIconRevision
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(program.name)
                    .font(.system(.callout, weight: .semibold))
                    .lineLimit(1)
                    .help(program.name)
                Text(displayPath(program.executablePath))
                    .font(.caption)
                    .foregroundStyle(WineTheme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(program.executablePath)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Launch") { model.launch(program, in: currentBottle) }
                .buttonStyle(WineButtonStyle(prominent: true))
                .disabled(launchUnavailable)
                .accessibilityLabel("Launch \(program.name)")
            Menu {
                Button("Remove from MagicWine", role: .destructive) {
                    model.removeProgram(program, in: currentBottle)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 20, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(busy)
            .accessibilityLabel("Actions for \(program.name)")
            .help("Remove this program from MagicWine without deleting its file")
        }
        .padding(.vertical, 10)
        .contextMenu {
            Button("Launch") { model.launch(program, in: currentBottle) }
                .disabled(launchUnavailable)
            Button("Remove from MagicWine", role: .destructive) {
                model.removeProgram(program, in: currentBottle)
            }
            .disabled(busy)
        }
    }

    private func displayPath(_ path: String) -> String {
        let prefix = bottleURL.appendingPathComponent("prefix", isDirectory: true).path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private var quickActions: some View {
        WineCard(title: "Quick Actions", icon: "bolt") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                quickAction("Install Game/Application", subtitle: "Run an EXE or MSI installer", icon: "gamecontroller", unavailable: operationUnavailable) {
                    model.chooseInstaller(in: currentBottle)
                }
                quickAction("Add Program", subtitle: "Add a custom executable", icon: "plus", unavailable: operationUnavailable) {
                    model.chooseProgram(in: currentBottle)
                }
                quickAction("Refresh Shortcuts", subtitle: "Scan for new programs", icon: "arrow.clockwise", unavailable: operationUnavailable) {
                    model.refreshPrograms(in: currentBottle)
                }
                quickAction("Open Bottle Folder", subtitle: "Show in Finder", icon: "folder", unavailable: false) {
                    NSWorkspace.shared.activateFileViewerSelecting([bottleURL])
                }
            }
        }
    }

    private func quickAction(_ title: String, subtitle: String, icon: String, unavailable: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(WineTheme.text)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(WineTheme.muted).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        }
        .buttonStyle(WineButtonStyle())
        .disabled(unavailable)
        .help(title == "Open Bottle Folder" ? bottleURL.path : title)
    }

    private var performanceAndRuntime: some View {
        WineCard(title: "Performance & Runtime", icon: "speedometer") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Label("Wine version", systemImage: "wineglass")
                        .font(.callout).foregroundStyle(WineTheme.muted)
                    Spacer(minLength: 0)
                    Text(currentBottle.runtime.version).font(.callout)
                        .help(currentBottle.runtime.executableURL.path)
                    Button("Configure") { model.configure(currentBottle) }
                        .buttonStyle(WineButtonStyle())
                        .disabled(operationUnavailable)
                        .help("Open this bottle’s Wine configuration dialog")
                }
                rowSeparator
                GraphicsSettingsView(model: model, bottle: currentBottle, busy: busy)
                if let componentID = currentBottle.graphics.componentID {
                    Text("Graphics component: \(componentID)")
                        .font(.caption)
                        .foregroundStyle(WineTheme.muted)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var tools: some View {
        WineCard(title: "Tools", icon: "wrench.and.screwdriver") {
            HStack(spacing: 8) {
                toolButton("Reveal C: Drive", icon: "internaldrive") { model.revealDrive(currentBottle) }
                    .disabled(!currentBottle.isInitialized)
                    .help("Reveal this bottle’s Windows drive in Finder")
                toolButton("Reveal Logs", icon: "doc.text") { model.revealLogs(for: currentBottle) }
                    .help("Reveal the latest operation log, or the logs folder")
                toolButton("Trash Bottle…", icon: "trash", destructive: true, action: trash)
                    .disabled(busy)
                    .help("Ask for confirmation before moving this bottle to Trash")
            }
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

    private var rowSeparator: some View {
        Rectangle()
            .fill(WineTheme.border)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
