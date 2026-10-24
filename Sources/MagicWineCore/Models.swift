import Foundation

public struct ApplicationPaths: Sendable {
    public let root: URL
    public var bottlesDirectory: URL { root.appendingPathComponent("Bottles", isDirectory: true) }
    public var runtimesDirectory: URL { root.appendingPathComponent("Runtimes", isDirectory: true) }
    public var componentsDirectory: URL { root.appendingPathComponent("Components", isDirectory: true) }
    public var logsDirectory: URL { root.appendingPathComponent("Logs", isDirectory: true) }
    public var settingsURL: URL { root.appendingPathComponent("settings.json") }

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MagicWine", isDirectory: true)
    }

    public func prepare() throws {
        for directory in [root, bottlesDirectory, runtimesDirectory, componentsDirectory, logsDirectory] {
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

public struct DisplayConfiguration: Codable, Hashable, Sendable {
    public var retinaEnabled: Bool
    public var dpi: UInt32

    public init(retinaEnabled: Bool = true, dpi: UInt32? = nil) {
        self.retinaEnabled = retinaEnabled
        self.dpi = dpi ?? (retinaEnabled ? 192 : 96)
    }
}

public struct Bottle: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public internal(set) var runtime: RuntimeDescriptor
    public var isInitialized: Bool
    public var programs: [WindowsProgram]
    public var graphics: GraphicsConfiguration
    public var msyncEnabled: Bool
    private var displayPreference: DisplayConfiguration?
    public var display: DisplayConfiguration {
        get { displayPreference ?? .init() }
        set { displayPreference = newValue }
    }
    internal var hasDisplayConfiguration: Bool { displayPreference != nil }

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), runtime: RuntimeDescriptor,
                isInitialized: Bool = false, programs: [WindowsProgram] = [], graphics: GraphicsConfiguration = .init(),
                display: DisplayConfiguration = .init(), msyncEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.runtime = runtime
        self.isInitialized = isInitialized
        self.programs = programs
        self.graphics = graphics
        self.displayPreference = display
        self.msyncEnabled = msyncEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, runtime, isInitialized, programs, graphics, msyncEnabled
        case displayPreference = "display"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        runtime = try container.decode(RuntimeDescriptor.self, forKey: .runtime)
        isInitialized = try container.decode(Bool.self, forKey: .isInitialized)
        programs = try container.decode([WindowsProgram].self, forKey: .programs)
        if container.contains(.graphics) {
            graphics = try container.decode(GraphicsConfiguration.self, forKey: .graphics)
        } else {
            graphics = .init()
        }
        displayPreference = container.contains(.displayPreference)
            ? try container.decode(DisplayConfiguration.self, forKey: .displayPreference) : nil
        msyncEnabled = container.contains(.msyncEnabled)
            ? try container.decode(Bool.self, forKey: .msyncEnabled) : true
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

/// Delivered once, as soon as a Windows program's process has started; a game or
/// launcher can then run for hours before its `OperationResult` arrives.
public struct LaunchStart: Sendable {
    public let logURL: URL
    /// Optional compatibility integrations skipped for this launch. The program
    /// still runs; each warning is also written at the top of its log.
    public let warnings: [String]

    public init(logURL: URL, warnings: [String]) {
        self.logURL = logURL
        self.warnings = warnings
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
    case stopped(logURL: URL)

    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a name between 1 and 80 characters."
        case .invalidProgram(let path): "Choose an existing Windows EXE or shortcut: \(path)"
        case .invalidBottle: "The bottle is missing or its metadata is invalid."
        case .runtimeUnavailable(let detail): "Wine is unavailable. \(detail)"
        case .processFailed(let code, let url): "Wine exited with code \(code). See the log at \(url.path)."
        case .stopped(let url): "Operation stopped. Log: \(url.path)"
        case .setup(let detail): detail
        }
    }
}
