import SwiftUI
import MagicWineCore

enum LibraryDestination: Hashable {
    case bottles
    case gamepads
    case downloads
    case documentation
}

/// A selectable sidebar row: one bottle, or a library destination.
enum SidebarItem: Hashable {
    case bottle(UUID)
    case destination(LibraryDestination)
}

struct LibrarySidebarView: View {
    let model: AppModel
    @Binding var selection: SidebarItem?
    /// The window's search text: matches bottle names and their programs' names.
    let search: String
    let newBottle: () -> Void
    let trash: (Bottle) -> Void
    @Environment(\.openWindow) private var openWindow

    private var filteredBottles: [Bottle] {
        guard !search.isEmpty else { return model.library.bottles }
        return model.library.bottles.filter { bottle in
            bottle.name.localizedStandardContains(search)
                || bottle.programs.contains { $0.name.localizedStandardContains(search) }
        }
    }

    private static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .flatMap { $0.isEmpty ? nil : $0 } ?? "0.1.0"

    var body: some View {
        let bottles = filteredBottles
        List(selection: $selection) {
            Section {
                if model.library.bottles.isEmpty {
                    emptyLibrary
                } else if bottles.isEmpty {
                    emptySearch
                } else {
                    ForEach(bottles) { bottle in
                        InstallDropTarget(model: model, bottle: bottle) { bottleRow(bottle) }
                            .tag(SidebarItem.bottle(bottle.id))
                    }
                }
            } header: {
                HStack {
                    Text("Bottles")
                    Spacer()
                    Button(action: newBottle) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.library.isLoading)
                    .help("Create a bottle")
                    .accessibilityLabel("Create a bottle")
                }
            }

            Section("Library") {
                destinationRow("Gamepads", icon: "gamecontroller", target: .gamepads)
                destinationRow("Downloads", icon: "arrow.down.to.line", target: .downloads,
                               active: model.runtimes.activity != nil)
                destinationRow("Documentation", icon: "book", target: .documentation)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(WineTheme.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            branding
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MagicWine \(Self.appVersion)")
                    .font(.system(size: 12, weight: .medium))
                Text("Run Windows your way.")
                    .font(.system(size: 12))
            }
            .foregroundStyle(WineTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private var branding: some View {
        HStack(spacing: 10) {
            Image(nsImage: WineArtwork.logo)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("MagicWine")
                    .font(.system(size: 24, weight: .regular, design: .serif))
                    .foregroundStyle(WineTheme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
                Text("Windows games. Pure magic.")
                    .font(.system(size: 10))
                    .foregroundStyle(WineTheme.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bottleRow(_ bottle: Bottle) -> some View {
        let activity = model.activity.activity(for: bottle)
        return HStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 18, weight: .light))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(bottle.name)
                    .font(.system(size: 14))
                    .lineLimit(1)
                if activity.isStopping {
                    rowSubtitle("Stopping Windows processes…")
                } else if let title = activity.title {
                    rowSubtitle(title)
                } else if activity.hasRunningPrograms {
                    rowSubtitle("Running: " + activity.runningProgramNames.joined(separator: ", "))
                } else if !bottle.isInitialized {
                    rowSubtitle("Setup needed")
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Show Logs…") { openWindow(id: BottleLogsView.windowID, value: bottle.id) }
            Button("Move Bottle to Trash…", role: .destructive) {
                guard !model.activity.activity(for: bottle).blocksPrefixMutation else { return }
                trash(bottle)
            }
            .disabled(activity.blocksPrefixMutation)
        }
    }

    private func rowSubtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(WineTheme.muted)
            .lineLimit(1)
    }

    private func destinationRow(_ title: String, icon: String, target: LibraryDestination,
                                active: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .light))
                .frame(width: 24)
            Text(title).font(.system(size: 14))
            Spacer(minLength: 0)
            if active {
                Circle().fill(WineTheme.success).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 3)
        .accessibilityValue(active ? "Download activity in progress" : "")
        .tag(SidebarItem.destination(target))
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.library.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading bottles…")
                }
            } else {
                Text("No bottles yet").foregroundStyle(WineTheme.text)
                Text("Create a bottle to start your Windows library.")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(WineTheme.muted)
        .padding(.vertical, 6)
    }

    private var emptySearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No matching bottles or programs").foregroundStyle(WineTheme.text)
            Text("Try another name or clear the search.")
        }
        .font(.system(size: 12))
        .foregroundStyle(WineTheme.muted)
        .padding(.vertical, 6)
    }
}

/// Installs the EXE/MSI file dropped on a bottle's row, like Install EXE/MSI: the bottle must be
/// set up and idle. The row is highlighted only while a drop can start the installer.
private struct InstallDropTarget<Content: View>: View {
    let model: AppModel
    let bottle: Bottle
    @ViewBuilder let content: () -> Content
    @State private var isTargeted = false

    var body: some View {
        let current = model.library.current(bottle)
        let available = current.isInitialized && !model.activity.activity(for: current).blocksPrefixMutation
        content()
            .fileDrop(isEnabled: available, targeted: $isTargeted) { model.install(dropped: $0, in: current) }
            .dropHighlight(isTargeted, cornerRadius: 6)
    }
}
