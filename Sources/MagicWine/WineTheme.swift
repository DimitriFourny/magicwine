import AppKit
import SwiftUI
import MagicWineCore

enum WineTheme {
    static let background = Color(red: 0.065, green: 0.055, blue: 0.075)
    static let sidebar = Color(red: 0.115, green: 0.080, blue: 0.115)
    static let panel = Color(red: 0.125, green: 0.108, blue: 0.135)
    static let elevated = Color(red: 0.180, green: 0.145, blue: 0.185)
    static let border = Color.white.opacity(0.09)
    static let accent = Color(red: 0.65, green: 0.18, blue: 0.37)
    static let text = Color(red: 0.96, green: 0.94, blue: 0.96)
    static let muted = Color(red: 0.69, green: 0.64, blue: 0.70)
    static let success = Color(red: 0.34, green: 0.83, blue: 0.48)
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

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(WineTheme.text)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(LinearGradient(
                        colors: prominent
                            ? [WineTheme.accent, WineTheme.accent.opacity(0.62)]
                            : [WineTheme.elevated, WineTheme.elevated.opacity(0.72)],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(prominent ? 0.13 : 0.07))
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.4)
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
                    .font(.system(size: 19))
                    .foregroundStyle(WineTheme.muted)
                    .frame(width: 22)
                Text(title).font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
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
    @ObservedObject var model: AppModel
    let bottle: Bottle

    private var state: BottleActivity { model.activity(for: bottle) }
    private var title: String {
        if state.isStopping { return "Stopping…" }
        if state.title != nil { return "Busy" }
        if state.error != nil { return "Needs attention" }
        if state.hasRunningPrograms { return "Running" }
        return bottle.isInitialized ? "Ready" : "Setup needed"
    }
    private var color: Color {
        if state.isStopping || state.title != nil { return .orange }
        if state.error != nil { return .red }
        return bottle.isInitialized ? WineTheme.success : .orange
    }

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(color.opacity(0.10), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
