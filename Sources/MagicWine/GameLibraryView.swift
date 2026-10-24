import SwiftUI
import MagicWineCore

/// One program of one bottle, as the game library lists it.
struct LibraryGame: Identifiable {
    let bottle: Bottle
    let program: WindowsProgram
    var id: UUID { program.id }
}

/// Every program of every bottle, each in exactly one section: favorites first, then the
/// programs launched most recently, then the rest by name.
struct GameLibrarySections {
    /// How many launched programs the Recently Played section shows; older ones are listed with the rest.
    static let recentLimit = 8

    private(set) var favorites: [LibraryGame] = []
    private(set) var recent: [LibraryGame] = []
    private(set) var others: [LibraryGame] = []

    var count: Int { favorites.count + recent.count + others.count }

    /// `search` keeps programs whose name or bottle name matches.
    init(bottles: [Bottle], search: String) {
        let games = bottles.flatMap { bottle in bottle.programs.map { LibraryGame(bottle: bottle, program: $0) } }
            .filter { search.isEmpty || $0.program.name.localizedStandardContains(search)
                || $0.bottle.name.localizedStandardContains(search) }
        func byName(_ left: LibraryGame, _ right: LibraryGame) -> Bool {
            let comparison = left.program.name.localizedStandardCompare(right.program.name)
            return comparison == .orderedSame ? left.bottle.name.localizedStandardCompare(right.bottle.name) == .orderedAscending
                : comparison == .orderedAscending
        }
        func byRecency(_ left: LibraryGame, _ right: LibraryGame) -> Bool {
            let (l, r) = (left.program.lastLaunchedAt ?? .distantPast, right.program.lastLaunchedAt ?? .distantPast)
            return l != r ? l > r : byName(left, right)
        }
        favorites = games.filter(\.program.isFavorite).sorted(by: byRecency)
        let rest = games.filter { !$0.program.isFavorite }
        let launched = rest.filter { $0.program.lastLaunchedAt != nil }.sorted(by: byRecency)
        recent = Array(launched.prefix(Self.recentLimit))
        let shown = Set(recent.map(\.id))
        others = rest.filter { !shown.contains($0.id) }.sorted(by: byName)
    }
}

/// The "All Games" destination: programs across all bottles with their favorite star, play
/// history, and running state, using the same launch and library-edit gates as a bottle's
/// dashboard. `showBottle` jumps to the program's bottle.
struct GameLibraryView: View {
    let model: AppModel
    /// The window's search text: matches program and bottle names.
    let search: String
    let showBottle: (UUID) -> Void

    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 460), spacing: 14, alignment: .top)]

    var body: some View {
        let sections = GameLibrarySections(bottles: model.library.bottles, search: search)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(count: sections.count)
                if model.library.isLoading {
                    ProgressView("Loading your library…")
                } else if sections.count == 0 {
                    empty
                } else {
                    section("Favorites", sections.favorites)
                    section("Recently Played", sections.recent)
                    section(sections.favorites.isEmpty && sections.recent.isEmpty ? "Programs" : "All Programs", sections.others)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("All Games")
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("All Games")
                .font(WineTheme.Font.display)
                .accessibilityAddTraits(.isHeader)
            Text(localized("\(count) programs in \(model.library.bottles.count) bottles"))
                .foregroundStyle(WineTheme.muted)
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ games: [LibraryGame]) -> some View {
        if !games.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(WineTheme.Font.heading)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(games) { game in
                        GameCard(model: model, game: game, showBottle: showBottle)
                    }
                }
            }
        }
    }

    private var empty: some View {
        WineCard(title: search.isEmpty ? "No programs yet" : "No matching programs", icon: "app.dashed") {
            Text(search.isEmpty
                 ? "Install or add a program in a bottle and it appears here, with your favorites and recently played programs first."
                 : "No program or bottle name matches “\(search)”. Clear the search to see every program.")
                .font(WineTheme.Font.callout)
                .foregroundStyle(WineTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A program in the game library: launch, favorite, running state, and a jump to its bottle.
private struct GameCard: View {
    let model: AppModel
    let game: LibraryGame
    let showBottle: (UUID) -> Void
    @Environment(\.openWindow) private var openWindow

    /// The latest record of the bottle and program, as `model.library` holds them.
    private var bottle: Bottle { model.library.current(game.bottle) }
    private var program: WindowsProgram { bottle.programs.first { $0.id == game.program.id } ?? game.program }
    private var state: BottleActivity { model.activity.activity(for: bottle) }
    private var isRunning: Bool { state.isRunning(program) }
    private var launchUnavailable: Bool { state.blocksLaunch || !bottle.isInitialized }
    private var runningLog: LiveLog? {
        model.activity.liveLogs(for: bottle).last { $0.programID == program.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                WindowsProgramIconView(
                    executablePath: program.executablePath,
                    prefix: model.library.bottleURL(for: bottle).appendingPathComponent("prefix", isDirectory: true),
                    revision: model.library.iconRevision(for: bottle.id)
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(program.name)
                            .font(WineTheme.Font.subheading)
                            .lineLimit(1)
                            .help(program.name)
                        if isRunning {
                            Text("Running")
                                .font(WineTheme.Font.small.weight(.medium))
                                .foregroundStyle(WineTheme.success)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(WineTheme.success.opacity(0.12), in: Capsule())
                        }
                    }
                    Button { showBottle(bottle.id) } label: {
                        Label(bottle.name, systemImage: "shippingbox")
                            .font(WineTheme.Font.small)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(WineTheme.accentGlyph)
                    .help("Show \(bottle.name)")
                    .accessibilityLabel("Show bottle \(bottle.name)")
                    Text(ProgramHistory.summary(of: program))
                        .font(WineTheme.Font.small)
                        .foregroundStyle(WineTheme.muted)
                        .lineLimit(2)
                    if let graphics = program.graphics {
                        Label(graphics.backend.displayName, systemImage: "cpu")
                            .font(WineTheme.Font.small)
                            .foregroundStyle(WineTheme.muted)
                            .help("This program uses its own graphics backend")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                favoriteButton
            }
            HStack(spacing: 8) {
                Button { model.activity.launch(program, in: bottle) } label: {
                    Label("Launch", systemImage: "play.fill")
                        .frame(minWidth: 72)
                }
                .buttonStyle(WineButtonStyle(prominent: true))
                .disabled(launchUnavailable)
                .accessibilityLabel("Launch \(program.name)")
                .help(isRunning ? "Running. Launch again to reopen a background app." : "Launch \(program.name)")
                if let runningLog {
                    Button { openWindow(id: LogViewerView.windowID, value: runningLog.url) } label: {
                        Label("Running Log", systemImage: "doc.text")
                    }
                    .buttonStyle(WineButtonStyle())
                    .help("Follow the output of this running launch")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(WineTheme.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(WineTheme.border) }
        .accessibilityElement(children: .contain)
        .contextMenu {
            Button("Launch") { model.activity.launch(program, in: bottle) }
                .disabled(launchUnavailable)
            if let runningLog {
                Button("Show Running Log") { openWindow(id: LogViewerView.windowID, value: runningLog.url) }
            }
            Button("Show in \(bottle.name)") { showBottle(bottle.id) }
            Divider()
            Button(program.isFavorite ? localized("Remove from Favorites") : localized("Add to Favorites"), action: toggleFavorite)
                .disabled(state.blocksLibraryEdit)
        }
    }

    private var favoriteButton: some View {
        Button(action: toggleFavorite) {
            Image(systemName: program.isFavorite ? "star.fill" : "star")
                .foregroundStyle(program.isFavorite ? WineTheme.favorite : WineTheme.muted)
        }
        .buttonStyle(.borderless)
        .disabled(state.blocksLibraryEdit)
        .accessibilityLabel(program.isFavorite ? localized("Remove \(program.name) from Favorites") : localized("Add \(program.name) to Favorites"))
        .help(program.isFavorite ? localized("Remove from Favorites") : localized("Add to Favorites; favorites are listed first"))
    }

    private func toggleFavorite() {
        model.bottleSettings.setFavorite(!program.isFavorite, for: program, in: bottle)
    }
}
