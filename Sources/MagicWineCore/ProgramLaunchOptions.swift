import Foundation

/// Validation and argument syntax for per-program launch options.
extension WindowsProgram {
    public static let maximumArguments = 256
    public static let maximumEnvironmentVariables = 64

    /// LNK/URL files are dispatched with `wine start /unix`, which starts the shortcut's
    /// own target with the shortcut's own arguments and directory. Only environment and
    /// DLL overrides apply to them (inherited by the process Wine starts).
    public var supportsArgumentsAndDirectory: Bool {
        URL(fileURLWithPath: executablePath).pathExtension.lowercased() == "exe"
    }

    /// Why a variable cannot be set per program, or `nil` when it can. Keys that select
    /// the prefix, loader, server, DLL search path, synchronization protocol, host loader,
    /// or MagicWine's own integrations would break bottle isolation or pinned components.
    public static func environmentKeyProblem(_ key: String) -> String? {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        guard let first = key.first, !first.isNumber, key.count <= 128, key.allSatisfy(allowed.contains) else {
            return "Use letters, digits, and underscores, not starting with a digit."
        }
        if key == "WINEDLLOVERRIDES" { return "Use DLL overrides instead; MagicWine merges them with its own." }
        if key.hasPrefix("WINE") && key != "WINEDEBUG" && !key.hasPrefix("WINE_") {
            return "\(key) belongs to MagicWine's prefix, runtime, or synchronization setup."
        }
        if key == "PATH" || key.hasPrefix("DYLD_") || key.hasPrefix("MAGICWINE_") || key == "CX_APPLEGPTK_LIBD3DSHARED_PATH" {
            return "\(key) would replace MagicWine's pinned runtime or integrations."
        }
        return nil
    }

    public static func environmentValueProblem(_ value: String) -> String? {
        if value.contains("\0") { return "Values cannot contain NUL characters." }
        if value.utf8.count > 4096 { return "Values are limited to 4096 bytes." }
        return nil
    }

    /// Throws for options that `BottleStore.updateProgram` must not save and a launch
    /// must not use (including hand-edited metadata).
    public func validateLaunchOptions() throws {
        guard arguments.count <= Self.maximumArguments,
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 32_768 }) else {
            throw MagicWineError.invalidInput("Use at most \(Self.maximumArguments) arguments without NUL characters.")
        }
        if !supportsArgumentsAndDirectory, !arguments.isEmpty || workingDirectory != nil {
            throw MagicWineError.invalidInput("Arguments and a working directory apply only to EXE programs. Wine starts LNK and URL shortcuts with their own arguments and folder.")
        }
        if let workingDirectory {
            guard workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0") else {
                throw MagicWineError.invalidInput("The working directory must be an absolute Mac folder path.")
            }
        }
        guard environment.count <= Self.maximumEnvironmentVariables else {
            throw MagicWineError.invalidInput("Use at most \(Self.maximumEnvironmentVariables) environment variables.")
        }
        for (key, value) in environment {
            if let problem = Self.environmentKeyProblem(key) ?? Self.environmentValueProblem(value) {
                throw MagicWineError.invalidInput("Environment variable \(key): \(problem)")
            }
        }
        if let graphics {
            // Only a backend a launch can supply without prefix files names its own component.
            if let provider = graphics.backend.componentProvider, provider.launchesWithoutPrefixFiles {
                guard let componentID = graphics.componentID, provider.supports(componentID: componentID) else {
                    throw MagicWineError.invalidInput("\(graphics.backend.displayName) graphics for a program needs a supported component.")
                }
            } else if graphics.componentID != nil {
                throw MagicWineError.invalidInput("\(graphics.backend.displayName) graphics for a program uses the bottle’s files and has no component of its own.")
            }
        }
    }

    /// The working directory, which must exist as a folder when the program launches.
    func launchDirectory() throws -> URL? {
        guard let workingDirectory else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &directory), directory.boolValue else {
            throw MagicWineError.invalidInput("The working directory for \(name) is missing or not a folder: \(workingDirectory). Edit the program to choose another folder or reset it.")
        }
        return URL(fileURLWithPath: workingDirectory, isDirectory: true).standardizedFileURL
    }

    /// Splits text on whitespace. Single quotes are literal; double quotes allow `\"` and
    /// `\\`. Backslashes elsewhere are literal, so Windows paths need no escaping.
    public static func parseArguments(_ text: String) throws -> [String] {
        var result: [String] = []
        var token = ""
        var hasToken = false
        var quote: Character?
        var iterator = text.makeIterator()
        while let character = iterator.next() {
            switch quote {
            case "'":
                if character == "'" { quote = nil } else { token.append(character) }
            case "\"":
                if character == "\"" {
                    quote = nil
                } else if character == "\\" {
                    guard let next = iterator.next() else { token.append(character); continue }
                    if next == "\"" || next == "\\" { token.append(next) } else { token.append(character); token.append(next) }
                } else {
                    token.append(character)
                }
            default:
                if character.isWhitespace {
                    if hasToken { result.append(token) }
                    token = ""
                    hasToken = false
                } else if character == "'" || character == "\"" {
                    quote = character
                    hasToken = true
                } else {
                    token.append(character)
                    hasToken = true
                }
            }
        }
        guard quote == nil else { throw MagicWineError.invalidInput("Close the quote in the arguments.") }
        if hasToken { result.append(token) }
        return result
    }

    /// Inverse of `parseArguments`: `parseArguments(formatArguments(x)) == x`.
    public static func formatArguments(_ arguments: [String]) -> String {
        arguments.map { argument in
            guard argument.isEmpty || argument.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" }) else {
                return argument
            }
            if !argument.contains("'") { return "'" + argument + "'" }
            return "\"" + argument.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }.joined(separator: " ")
    }
}
