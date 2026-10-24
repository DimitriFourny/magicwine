import Foundation

/// A failure of a MagicWine operation. Each case says what kind of problem occurred;
/// `errorDescription` is a readable message without file paths of logs, `logURL` is the
/// log that explains it, and `recoveryActions` are what may fix it. Messages and
/// `recoverySuggestion` name neither command-line flags nor app buttons: the app renders
/// the actions as buttons and `magicwine` renders them as commands
/// (`CommandLineErrorReport`).
public enum MagicWineError: LocalizedError, Sendable {
    case invalidName
    case invalidProgram(String)
    case invalidBottle
    /// A value supplied by the caller is malformed or not applicable (arguments, DLL
    /// overrides, environment variables, unknown dependencies, command usage).
    case invalidInput(String)
    /// The bottle must be set up before this operation.
    case notInitialized(String)
    /// Another operation or the bottle's running Windows programs hold it.
    case busy(String, reason: BusyReason, logURL: URL? = nil)
    /// The bottle was changed elsewhere since the caller read it.
    case conflict(String)
    /// The operation needs explicit consent that was not given.
    case consentRequired(String, Consent)
    case timedOut(String, logURL: URL? = nil)
    /// A process exited with a nonzero status or was terminated by a signal.
    case processFailed(exitCode: Int32, logURL: URL)
    /// Stop interrupted the operation; not a failure to report as such.
    case stopped(logURL: URL)
    /// An operation failed; its log has the details. `recovery` keeps what may fix the
    /// underlying failure (see `failed(_:logURL:underlying:)`).
    case operationFailed(String, logURL: URL, recovery: [RecoveryAction] = [])
    /// The Wine executable cannot run at all.
    case runtimeUnavailable(String, remedy: RuntimeRemedy = .chooseWine, logURL: URL? = nil)
    /// The bottle's Wine runs but lacks something the request needs.
    case runtimeIncompatible(String, remedy: RuntimeRemedy)
    /// The bottle's graphics component is unsupported, missing, damaged, does not match the
    /// prefix, or can only be replaced from Standard graphics; restoring Standard (or
    /// updating an older supported component) fixes it.
    case componentInvalid(String)
    /// This Mac cannot run the requested component.
    case hostUnsupported(String)
    /// A file, archive, receipt, or backup does not match its pin or expected layout.
    case integrityFailure(String)
    /// A refusal to follow links, adopt unexpected file types, or overwrite files
    /// MagicWine did not install.
    case unsafeFilesystem(String)
    /// Saved data in a format newer than this build reads; it is left unchanged so no
    /// field this build does not know is lost.
    case newerVersion(String)
    case downloadFailed(String)
    /// Failures without a more specific kind (unexpected system errors, internal invariants).
    case setup(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a name between 1 and 80 characters."
        case .invalidProgram(let path): "Choose an existing Windows EXE or shortcut: \(path)"
        case .invalidBottle: "The bottle is missing or its metadata is invalid."
        case .runtimeUnavailable(let detail, _, _): "Wine is unavailable. \(detail)"
        case .processFailed(let code, _): "Wine exited with code \(code)."
        case .stopped: "Operation stopped."
        case .invalidInput(let message), .notInitialized(let message), .busy(let message, _, _),
             .conflict(let message), .consentRequired(let message, _), .timedOut(let message, _),
             .operationFailed(let message, _, _), .runtimeIncompatible(let message, _), .componentInvalid(let message),
             .hostUnsupported(let message), .integrityFailure(let message), .unsafeFilesystem(let message),
             .newerVersion(let message),
             .downloadFailed(let message), .setup(let message):
            message
        }
    }

    /// The log that explains this failure, if one was written.
    public var logURL: URL? {
        switch self {
        case .processFailed(_, let url), .stopped(let url), .operationFailed(_, let url, _): url
        case .busy(_, _, let url), .timedOut(_, let url), .runtimeUnavailable(_, _, let url): url
        default: nil
        }
    }

    /// What may fix the failure, most direct first. Surfaces offer the ones they can
    /// perform for the bottle's current state (`RecoveryAction.isAvailable(for:)`).
    public var recoveryActions: [RecoveryAction] {
        var actions: [RecoveryAction] = logURL.map { [.showLog($0)] } ?? []
        switch self {
        case .busy(_, .programsRunning, _): actions.append(.stopBottle)
        case .busy(_, .operationInProgress, _), .timedOut, .downloadFailed: actions.append(.retry)
        case .conflict: actions.append(.reload)
        case .notInitialized: actions.append(.retrySetup)
        case .consentRequired(_, let consent): actions.append(.giveConsent(consent))
        case .runtimeUnavailable(_, let remedy, _), .runtimeIncompatible(_, let remedy): actions.append(remedy.action)
        case .componentInvalid: actions += [.restoreStandardGraphics, .updateGraphicsComponent]
        case .operationFailed(_, _, let recovery): actions += recovery
        default: break
        }
        return actions
    }

    public var recoverySuggestion: String? {
        if case .busy(_, .operationInProgress, _) = self { return "Wait for it to finish, then try again." }
        if case .newerVersion = self { return "Use the newer version of MagicWine that saved it; this version changes nothing in it." }
        let suggestions = recoveryActions.compactMap(\.suggestion)
        return suggestions.isEmpty ? nil : suggestions.joined(separator: " ")
    }

    /// Wraps `error` as a failed operation explained by `logURL`, keeping the underlying
    /// failure's recovery actions (its own log, if any, is superseded by `logURL`).
    public static func failed(_ message: String, logURL: URL, underlying error: any Error) -> MagicWineError {
        let recovery = (error as? MagicWineError)?.recoveryActions.filter {
            if case .showLog = $0 { false } else { true }
        } ?? []
        return .operationFailed(message, logURL: logURL, recovery: recovery)
    }

    /// The same failure explained by `url`, an operation log that covers it, instead of
    /// its own log. Kinds without a replaceable log become `operationFailed` with the same
    /// message and recovery actions.
    public func withLog(_ url: URL) -> MagicWineError {
        switch self {
        case .busy(let message, let reason, _): .busy(message, reason: reason, logURL: url)
        case .timedOut(let message, _): .timedOut(message, logURL: url)
        case .runtimeUnavailable(let message, let remedy, _): .runtimeUnavailable(message, remedy: remedy, logURL: url)
        case .operationFailed(let message, _, let recovery): .operationFailed(message, logURL: url, recovery: recovery)
        default: .failed(errorDescription ?? "", logURL: url, underlying: self)
        }
    }
}

public enum BusyReason: Sendable {
    /// Windows programs (or a Wine server) of the bottle are still running.
    case programsRunning
    /// Another setup, installation, or launch of the bottle is in progress.
    case operationInProgress
}

/// What a person must explicitly accept before MagicWine proceeds.
public enum Consent: Hashable, Sendable {
    /// Running the unsigned managed Wine build and removing its download quarantine.
    case unsignedWine
    /// Installing an experimental third-party graphics component.
    case experimentalGraphics
    /// The licenses of Windows dependencies.
    case dependencyLicenses
}

/// How a bottle gets a Wine that can do what was requested.
public enum RuntimeRemedy: Sendable {
    /// The bottle uses an older MagicWine-managed Wine that can be switched in place.
    case updateWine
    /// Only another Wine in a new bottle helps; a bottle keeps its pinned Wine.
    case chooseWine
    /// This Wine needs Apple's Rosetta.
    case installRosetta

    var action: RecoveryAction {
        switch self {
        case .updateWine: .updateWine
        case .chooseWine: .chooseWine
        case .installRosetta: .installRosetta
        }
    }
}

/// Something a person or MagicWine can do about a failure.
public enum RecoveryAction: Hashable, Sendable {
    case showLog(URL)
    /// Quit or stop the bottle's Windows programs.
    case stopBottle
    /// Run bottle setup again.
    case retrySetup
    /// Restore the bottle's original Wine graphics files.
    case restoreStandardGraphics
    /// Switch the bottle's older supported component to the current bundled one.
    case updateGraphicsComponent
    /// Install the current managed Wine if needed and switch this bottle to it.
    case updateWine
    /// Install or choose another Wine and create a new bottle with it.
    case chooseWine
    case installRosetta
    case giveConsent(Consent)
    /// Read the bottle again before retrying.
    case reload
    case retry

    /// Surface-neutral guidance; `nil` for actions that need no explanation.
    public var suggestion: String? {
        switch self {
        case .showLog: nil
        case .stopBottle: "Quit this bottle’s Windows programs or stop the bottle, then try again."
        case .retrySetup: "Set up this bottle again."
        case .restoreStandardGraphics:
            "Restore Standard graphics to put back this bottle’s original graphics files, then enable the backend again."
        case .updateGraphicsComponent:
            "If this bottle uses an older supported component, updating it to the bundled one also replaces its files."
        case .updateWine:
            "Update this bottle’s Wine: the current MagicWine-managed Wine is installed if needed and only this bottle switches to it; custom Wine is never changed."
        case .chooseWine:
            "Install MagicWine’s managed Wine or choose a compatible Wine, then create a new bottle with it. An existing bottle keeps its Wine."
        case .installRosetta:
            "Install Rosetta through Apple’s macOS prompt or Apple’s software update tool after reviewing Apple’s license; MagicWine does not accept it for you."
        case .giveConsent(.unsignedWine): "Confirm that you trust the unsigned managed Wine build to continue."
        case .giveConsent(.experimentalGraphics): "Confirm the experimental third-party graphics component to continue."
        case .giveConsent(.dependencyLicenses): "Accept the dependencies’ licenses to continue."
        case .reload: "Reload the bottle and try again."
        case .retry: "Try again."
        }
    }

    /// Whether the action applies to `bottle` as it is now: graphics actions need a set-up
    /// bottle using a non-Standard backend (with an available update), setup retries an
    /// uninitialized bottle.
    public func isAvailable(for bottle: Bottle) -> Bool {
        switch self {
        case .restoreStandardGraphics: bottle.isInitialized && bottle.graphics.backend != .standard
        case .updateGraphicsComponent: bottle.isInitialized && bottle.graphics.hasComponentUpdate
        case .retrySetup: !bottle.isInitialized
        default: true
        }
    }
}
