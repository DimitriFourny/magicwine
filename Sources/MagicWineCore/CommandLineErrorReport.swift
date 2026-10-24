import Foundation

/// How `magicwine` reports a failure on standard error: the message, the log path when
/// one was written, and a line per recovery action, as a command where the CLI has one.
/// It lives in the core so the CLI rendering of the error taxonomy is tested; the app
/// renders the same `recoveryActions` as buttons.
public enum CommandLineErrorReport {
    /// `bottle`, when the command named an existing one, fills in its UUID and backend and
    /// drops actions that do not apply to it; `bottleID` alone only fills in the UUID.
    /// `invocation` prefixes every suggested command (for example with `--root`).
    public static func render(_ error: any Error, bottleID: UUID? = nil, bottle: Bottle? = nil,
                              invocation: String = "magicwine") -> String {
        guard let error = error as? MagicWineError else { return "error: \(error.localizedDescription)" }
        var lines = ["error: " + (error.errorDescription ?? "")]
        if let log = error.logURL { lines.append("log: \(log.path)") }
        let waitsForOperation = if case .busy(_, .operationInProgress, _) = error { true } else { false }
        for action in error.recoveryActions where bottle.map(action.isAvailable(for:)) ?? true {
            if waitsForOperation, action == .retry {
                lines.append("hint: wait for the other operation to finish, then run the command again")
            } else if let hint = hint(for: action, bottleID: bottle?.id ?? bottleID,
                                      backend: bottle?.graphics.backend, invocation: invocation) {
                lines.append("hint: " + hint)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// The command-line form of `action`; `nil` when the log line already covers it.
    public static func hint(for action: RecoveryAction, bottleID: UUID?, backend: GraphicsBackend?,
                            invocation: String = "magicwine") -> String? {
        let bottle = bottleID?.uuidString ?? "<bottle-UUID>"
        switch action {
        case .showLog: return nil
        case .stopBottle: return "run: \(invocation) stop \(bottle)"
        case .retrySetup: return "run: \(invocation) initialize \(bottle)"
        case .restoreStandardGraphics: return "run: \(invocation) graphics \(bottle) standard"
        case .updateGraphicsComponent:
            return "run: \(invocation) graphics \(bottle) \(backend?.rawValue ?? "<backend>") --update --accept-experimental"
        case .chooseProgramGraphics(let programID):
            return "run: \(invocation) program \(bottle) \(programID.uuidString) --graphics default (or another backend it lists)"
        case .updateWine:
            return "run: \(invocation) install-wine --accept-unsigned && \(invocation) runtime upgrade \(bottle)"
        case .chooseWine:
            return "run: \(invocation) install-wine --accept-unsigned (or list installed Wine with \(invocation) runtimes), then \(invocation) create <name> <wine-executable>"
        case .installRosetta:
            return "run: /usr/sbin/softwareupdate --install-rosetta (review Apple's license first; MagicWine does not accept it for you)"
        case .giveConsent(.unsignedWine): return "run the command again with --accept-unsigned"
        case .giveConsent(.experimentalGraphics): return "run the command again with --accept-experimental"
        case .giveConsent(.dependencyLicenses):
            return "review the licenses with \(invocation) deps \(bottle), then run the command again with --accept-license"
        case .reload: return "run the command again; it reads the bottle's current state"
        case .retry: return "run the command again"
        }
    }
}
