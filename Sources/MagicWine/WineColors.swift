import AppKit

/// MagicWine's colors as dynamic AppKit colors that resolve against the appearance they are
/// drawn in, so no view picks a color scheme. Both variants keep the wine-red identity: dark
/// uses a near-black plum with a lifted accent, light a warm paper with a deep accent.
///
/// Contrast (WCAG 2.x), measured by resolving every color under both appearances: `text`,
/// `muted`, `accentGlyph`, and the status colors reach 4.5:1 as text on `background`,
/// `sidebar`, `panel`, and `elevated`; `onAccent` reaches 4.5:1 on both ends of the accent
/// gradient; `accent` and `favorite` reach 3:1 as graphics on those surfaces.
enum WinePalette {
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    // Surfaces
    static let background = dynamic(light: rgb(0.965, 0.952, 0.965), dark: rgb(0.065, 0.055, 0.075))
    static let sidebar = dynamic(light: rgb(0.925, 0.895, 0.925), dark: rgb(0.115, 0.080, 0.115))
    static let panel = dynamic(light: rgb(1.0, 0.995, 1.0), dark: rgb(0.125, 0.108, 0.135))
    static let elevated = dynamic(light: rgb(0.925, 0.895, 0.935), dark: rgb(0.180, 0.145, 0.185))
    /// The darkest inset of a drawing, such as the gamepad body's lower edge.
    static let well = dynamic(light: rgb(0.80, 0.76, 0.81), dark: rgb(0.075, 0.065, 0.085))
    /// Hairlines and card outlines: a faint ink over any surface.
    static let border = dynamic(light: rgb(0, 0, 0, 0.12), dark: rgb(1, 1, 1, 0.09))
    /// The ink (white in dark, black in light) for hover and pressed overlays; use with `.opacity`.
    static let highlight = dynamic(light: rgb(0, 0, 0), dark: rgb(1, 1, 1))

    // Text
    static let text = dynamic(light: rgb(0.12, 0.09, 0.13), dark: rgb(0.96, 0.94, 0.96))
    static let muted = dynamic(light: rgb(0.36, 0.30, 0.38), dark: rgb(0.74, 0.69, 0.75))
    /// Text and icons on `accent` fills.
    static let onAccent = rgb(1, 1, 1)

    // Identity
    static let accent = dynamic(light: rgb(0.60, 0.13, 0.31), dark: rgb(0.78, 0.27, 0.47))
    /// The darker end of prominent button gradients.
    static let accentDeep = dynamic(light: rgb(0.47, 0.08, 0.24), dark: rgb(0.52, 0.12, 0.29))
    /// A lighter tone of the accent for glyphs on tinted panels.
    static let accentGlyph = dynamic(light: rgb(0.60, 0.13, 0.31), dark: rgb(0.94, 0.40, 0.63))

    // Status
    static let success = dynamic(light: rgb(0.08, 0.42, 0.18), dark: rgb(0.34, 0.83, 0.48))
    static let warning = dynamic(light: rgb(0.62, 0.33, 0.0), dark: rgb(1.0, 0.72, 0.30))
    static let danger = dynamic(light: rgb(0.72, 0.08, 0.20), dark: rgb(1.0, 0.42, 0.56))
    static let favorite = dynamic(light: rgb(0.68, 0.43, 0.0), dark: rgb(1.0, 0.80, 0.25))

    // Log lines (the viewer's text view draws them on `background`)
    static let logFixme = dynamic(light: rgb(0.40, 0.36, 0.42), dark: rgb(0.62, 0.62, 0.62))

    // The four face buttons of the gamepad diagram; the same hues as an Xbox controller.
    static let buttonY = dynamic(light: rgb(0.62, 0.43, 0.0), dark: rgb(1.0, 0.80, 0.25))
    static let buttonB = dynamic(light: rgb(0.72, 0.08, 0.20), dark: rgb(1.0, 0.42, 0.44))
    static let buttonA = dynamic(light: rgb(0.08, 0.42, 0.18), dark: rgb(0.34, 0.83, 0.48))
    static let buttonX = dynamic(light: rgb(0.10, 0.30, 0.78), dark: rgb(0.45, 0.63, 1.0))
}
