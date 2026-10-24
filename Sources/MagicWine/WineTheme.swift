import AppKit
import SwiftUI
import MagicWineCore

/// Semantic colors and type scale. Colors come from `WinePalette` and follow the system
/// appearance (light or dark); views never choose a color scheme or a literal color.
enum WineTheme {
    static let background = Color(nsColor: WinePalette.background)
    static let sidebar = Color(nsColor: WinePalette.sidebar)
    static let panel = Color(nsColor: WinePalette.panel)
    static let elevated = Color(nsColor: WinePalette.elevated)
    /// The darkest inset of a drawing (the gamepad body's lower edge).
    static let well = Color(nsColor: WinePalette.well)
    static let border = Color(nsColor: WinePalette.border)
    /// White in dark, black in light: hover and pressed overlays, with `.opacity`.
    static let highlight = Color(nsColor: WinePalette.highlight)
    static let text = Color(nsColor: WinePalette.text)
    static let muted = Color(nsColor: WinePalette.muted)
    /// The wine-red identity color: fills, strokes, and the tint. Text on it is `onAccent`.
    static let accent = Color(nsColor: WinePalette.accent)
    static let accentDeep = Color(nsColor: WinePalette.accentDeep)
    static let onAccent = Color(nsColor: WinePalette.onAccent)
    /// An accent-hued tone for glyphs on tinted panels.
    static let accentGlyph = Color(nsColor: WinePalette.accentGlyph)
    static let success = Color(nsColor: WinePalette.success)
    static let warning = Color(nsColor: WinePalette.warning)
    static let danger = Color(nsColor: WinePalette.danger)
    static let favorite = Color(nsColor: WinePalette.favorite)
    static let buttonY = Color(nsColor: WinePalette.buttonY)
    static let buttonB = Color(nsColor: WinePalette.buttonB)
    static let buttonA = Color(nsColor: WinePalette.buttonA)
    static let buttonX = Color(nsColor: WinePalette.buttonX)

    /// How strongly the dark cellar artwork shows behind a header: as drawn in dark, and as a
    /// faint watermark in light so text stays on a light surface.
    static func artworkOpacity(_ scheme: ColorScheme, dark: Double) -> Double {
        scheme == .dark ? dark : dark * 0.2
    }

    /// Text styles follow the system's text-style sizes. macOS has no Dynamic Type setting, so
    /// only the serif display titles and symbol sizes are fixed point sizes; they live here so
    /// views never carry a size literal.
    enum Font {
        /// Page titles: Welcome, Downloads, Documentation, Gamepads.
        static let display = SwiftUI.Font.system(size: 32, weight: .semibold, design: .serif)
        /// A bottle's name and the app name in the sidebar.
        static let title = SwiftUI.Font.system(size: 26, weight: .medium, design: .serif)
        /// Card and sheet headings.
        static let heading = SwiftUI.Font.system(.title2, weight: .semibold)
        /// Titles of items inside a card.
        static let subheading = SwiftUI.Font.system(.headline, weight: .semibold)
        static let body = SwiftUI.Font.body
        /// Button labels and row titles.
        static let label = SwiftUI.Font.system(.body, weight: .medium)
        static let callout = SwiftUI.Font.callout
        /// Status pills and secondary values.
        static let small = SwiftUI.Font.subheadline
        static let caption = SwiftUI.Font.caption
        static let mono = SwiftUI.Font.system(.callout, design: .monospaced)
        static let monoCaption = SwiftUI.Font.system(.caption, design: .monospaced)
        /// Symbols in headers, rows, and placeholders.
        static let iconHero = SwiftUI.Font.system(size: 48, weight: .light)
        static let iconLarge = SwiftUI.Font.system(size: 28)
        static let iconCard = SwiftUI.Font.system(size: 19)
        static let iconRow = SwiftUI.Font.system(size: 18, weight: .light)
    }
}

@MainActor
enum WineArtwork {
    static let bottle = load("bottle-art")
    static let cellar = load("cellar-art")
    static let logo = load("wine-logo")
    private static let bundle = Bundle.main.url(forResource: "MagicWine_MagicWine", withExtension: "bundle")
        .flatMap { Bundle(url: $0) } ?? .module

    private static func load(_ name: String) -> NSImage {
        guard let image = bundle.image(forResource: name) else {
            preconditionFailure("Missing bundled artwork: \(name)")
        }
        return image
    }
}

struct WineButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(WineTheme.Font.label)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(prominent ? WineTheme.onAccent : WineTheme.text)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: prominent
                            ? [WineTheme.accent, WineTheme.accentDeep]
                            : [WineTheme.elevated, WineTheme.elevated.opacity(0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(WineTheme.highlight.opacity(isEnabled && isHovered ? 0.08 : 0))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(WineTheme.highlight.opacity(isEnabled && isHovered ? 0.24 : (prominent ? 0.13 : 0.12)))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
            .onHover { isHovered = $0 }
    }
}

struct WineCard<Content: View>: View {
    let title: String
    let icon: String
    let trailing: String?
    @ViewBuilder let content: () -> Content

    init(title: String, icon: String, trailing: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(WineTheme.Font.iconCard)
                    .foregroundStyle(WineTheme.muted)
                    .frame(width: 22)
                Text(title).font(WineTheme.Font.heading)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(WineTheme.Font.callout)
                        .foregroundStyle(WineTheme.muted)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(WineTheme.elevated, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(colors: [WineTheme.panel, WineTheme.panel.opacity(0.82)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(WineTheme.border)
        }
    }
}

struct WineStatus: View {
    let model: AppModel
    let bottle: Bottle

    private var state: BottleActivity { model.activity.activity(for: bottle) }
    private var title: String {
        if state.isStopping { return "Stopping…" }
        if state.title != nil { return "Busy" }
        if state.error != nil { return "Needs attention" }
        if state.hasRunningPrograms { return "Running" }
        return bottle.isInitialized ? "Ready" : "Setup needed"
    }
    private var color: Color {
        if state.isStopping || state.title != nil { return WineTheme.warning }
        if state.error != nil { return WineTheme.danger }
        return bottle.isInitialized ? WineTheme.success : WineTheme.warning
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(WineTheme.Font.callout.weight(.medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
