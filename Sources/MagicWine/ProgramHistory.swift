import Foundation
import MagicWineCore

/// How the app words a program's recorded play history, shared by the bottle dashboard and
/// the game library.
enum ProgramHistory {
    /// "Last launched yesterday · 1 hr, 30 min played", or that it was never launched from
    /// MagicWine. Launches by the CLI are not recorded.
    static func summary(of program: WindowsProgram) -> String {
        guard let last = program.lastLaunchedAt else { return localized("Never launched from MagicWine") }
        let played = program.playTime < 60 ? localized("under a minute")
            : Duration.seconds(program.playTime).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
        return localized("Last launched \(last.formatted(.relative(presentation: .named))) · \(played) played")
    }
}
