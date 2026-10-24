import Foundation

extension Bundle {
    /// The app's SwiftPM resource bundle: `MagicWine_MagicWine.bundle` in a packaged app's
    /// `Contents/Resources`, else the module bundle of a plain `swift run` build. It holds the
    /// artwork and `Localization/<language>.lproj/Localizable.strings` and `.stringsdict`.
    /// `Text` literals use `Bundle.main`, which `scripts/build-app.sh` gives a copy of the same
    /// `.lproj` folders.
    static let wine: Bundle = Bundle.main.url(forResource: "MagicWine_MagicWine", withExtension: "bundle")
        .flatMap { Bundle(url: $0) } ?? .module
}

/// A user-facing string built in code (activity titles, notices, pluralized counts), looked up
/// in the app's `Localizable.strings`/`.stringsdict` with the key being the English text, `%@`
/// for string and `%lld` for integer interpolations. Plural rules follow the language of the
/// strings actually shown, not the system's region, so an English table never applies French
/// rules ("0 controller") to a French-region Mac. Core error messages stay English; see
/// `MagicWineError`.
func localized(_ value: String.LocalizationValue) -> String {
    let language = Bundle.wine.preferredLocalizations.first ?? "en"
    return String(localized: value, bundle: .wine, locale: Locale(identifier: language))
}
