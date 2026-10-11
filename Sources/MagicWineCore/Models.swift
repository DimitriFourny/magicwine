import Foundation

public struct ApplicationPaths: Sendable {
    public let root: URL
    public var bottlesDirectory: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    public var runtimesDirectory: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public var logsDirectory: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var settingsURL: URL { root.appendingPathComponent("settings.json") }

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicWine", isDirectory: true)
    }

    public func prepare() throws {
        for directory in [root, bottlesDirectory, runtimesDirectory, logsDirectory] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

public struct RuntimeDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: String { executableURL.path }
    public let executableURL: URL
    public let version: String

    public init(executableURL: URL, version: String) {
        self.executableURL = executableURL
        self.version = version
    }
}

public struct WindowsProgram: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let executablePath: String

    public init(id: UUID = UUID(), name: String, executablePath: String) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
    }
}

public struct Bottle: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public let runtime: RuntimeDescriptor
    public var isInitialized: Bool
    public var programs: [WindowsProgram]

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), runtime: RuntimeDescriptor,
                isInitialized: Bool = false, programs: [WindowsProgram] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.runtime = runtime
        self.isInitialized = isInitialized
        self.programs = programs
    }
}

public struct OperationResult: Sendable {
    public let exitCode: Int32
    public let logURL: URL

    public init(exitCode: Int32, logURL: URL) {
        self.exitCode = exitCode
        self.logURL = logURL
    }
}

public struct AppSettings: Codable, Sendable {
    public var customWinePath: String?
    public var preferredRuntimePath: String?

    public init(customWinePath: String? = nil, preferredRuntimePath: String? = nil) {
        self.customWinePath = customWinePath
        self.preferredRuntimePath = preferredRuntimePath
    }
}

public enum MagicWineError: LocalizedError, Sendable {
    case invalidName
    case invalidProgram(String)
    case invalidBottle
    case runtimeUnavailable(String)
    case processFailed(exitCode: Int32, logURL: URL)
    case setup(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a name between 1 and 80 characters."
        case .invalidProgram(let path): "Choose an existing Windows EXE or shortcut: \(path)"
        case .invalidBottle: "The bottle is missing or its metadata is invalid."
        case .runtimeUnavailable(let detail): "Wine is unavailable. \(detail)"
        case .processFailed(let code, let url): "Wine exited with code \(code). See the log at \(url.path)."
        case .setup(let detail): detail
        }
    }
}
