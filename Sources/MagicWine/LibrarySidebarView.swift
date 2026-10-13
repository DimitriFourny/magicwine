import SwiftUI
import MagicWineCore

enum LibraryDestination: Equatable {
    case bottles
    case gamepads
    case downloads
    case settings
    case documentation
}

struct LibrarySidebarView: View {
    @ObservedObject var model: AppModel
    @Binding var destination: LibraryDestination
    let search: String
    let trash: (Bottle) -> Void

    private var filteredBottles: [Bottle] {
        guard !search.isEmpty else { return model.bottles }
        return model.bottles.filter { $0.name.localizedStandardContains(search) }
    }

    private static let appVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .flatMap { $0.isEmpty ? nil : $0 } ?? "0.1.0"

    var body: some View {
        GeometryReader { geometry in
            let bottles = filteredBottles
            VStack(alignment: .leading, spacing: 0) {
                branding
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 24)

                HStack {
                    Text("Bottles")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(WineTheme.muted)
                    Spacer()
                    Button {
                        guard !model.isLoading else { return }
                        model.showsNewBottle = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .buttonStyle(WineButtonStyle())
                    .disabled(model.isLoading)
                    .help("Create a bottle")
                    .accessibilityLabel("Create a bottle")
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        if model.bottles.isEmpty {
                            emptyLibrary
                        } else if bottles.isEmpty {
                            emptySearch
                        } else {
                            ForEach(bottles) { bottle in
                                bottleRow(bottle)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .frame(height: min(max(CGFloat(bottles.count) * 52, 104), max(104, geometry.size.height - 478)))

                Rectangle()
                    .fill(WineTheme.border)
                    .frame(height: 1)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)

                VStack(spacing: 4) {
                    navigationRow("Gamepads", icon: "gamecontroller", target: .gamepads)
                    navigationRow("Downloads", icon: "arrow.down.to.line", target: .downloads,
                                  active: model.runtimeActivity != nil)
                    navigationRow("Settings", icon: "gearshape", target: .settings)
                    navigationRow("Documentation", icon: "book", target: .documentation)
                }
                .padding(.horizontal, 12)

                Spacer(minLength: 20)

                VStack(alignment: .leading, spacing: 6) {
                    Text("MagicWine \(Self.appVersion)")
                        .font(.system(size: 12, weight: .medium))
                    Text("Run Windows your way.")
                        .font(.system(size: 12))
                }
                .foregroundStyle(WineTheme.muted)
                .padding(.horizontal, 24)
                .padding(.bottom, 26)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(WineTheme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(WineTheme.border).frame(width: 1)
        }
    }

    private var branding: some View {
        HStack(spacing: 10) {
            Image(nsImage: WineArtwork.logo)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 70)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("MagicWine")
                    .font(.system(size: 27, weight: .regular, design: .serif))
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
    }

    private func bottleRow(_ bottle: Bottle) -> some View {
        let activity = model.activity(for: bottle)
        let busy = activity.title != nil || activity.isStopping
        let selected = destination == .bottles && model.selectedBottleID == bottle.id
        return Button {
            model.selectedBottleID = bottle.id
            destination = .bottles
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 21, weight: .light))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bottle.name)
                        .font(.system(size: 14, weight: selected ? .medium : .regular))
                        .lineLimit(1)
                    if activity.isStopping {
                        rowSubtitle("Stopping Windows processes…")
                    } else if let title = activity.title {
                        rowSubtitle(title)
                    } else if !bottle.isInitialized {
                        rowSubtitle("Setup needed")
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? WineTheme.text : WineTheme.muted)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(selected ? WineTheme.accent.opacity(0.32) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? WineTheme.accent.opacity(0.5) : .clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .contextMenu {
            Button("Reveal Logs") { model.revealLogs(for: bottle) }
            Button("Move Bottle to Trash…", role: .destructive) {
                let current = model.activity(for: bottle)
                guard current.title == nil, !current.isStopping else { return }
                trash(bottle)
            }
            .disabled(busy)
        }
    }

    private func rowSubtitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(WineTheme.muted)
            .lineLimit(1)
    }

    private func navigationRow(_ title: String, icon: String, target: LibraryDestination,
                               active: Bool = false) -> some View {
        let selected = destination == target
        return Button {
            destination = target
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .light))
                    .frame(width: 24)
                Text(title).font(.system(size: 14))
                Spacer(minLength: 0)
                if active {
                    Circle().fill(WineTheme.success).frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(selected ? WineTheme.text : WineTheme.muted)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(selected ? WineTheme.accent.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(active ? "Download activity in progress" : "")
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.isLoading {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var emptySearch: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No matching bottles").foregroundStyle(WineTheme.text)
            Text("Try another name or clear the search.")
        }
        .font(.system(size: 12))
        .foregroundStyle(WineTheme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}
