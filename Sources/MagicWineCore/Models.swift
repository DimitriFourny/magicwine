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
    /// Appended after the EXE path. Direct EXE launches only; see `supportsArgumentsAndDirectory`.
    public var arguments: [String]
    /// Host directory for a direct EXE launch; `nil` uses the EXE's folder.
    public var workingDirectory: String?
    /// Highest launch layer: wins over bottle and backend values of the same variable.
    public var environment: [String: String]
    /// Highest launch layer: wins over bottle, backend, and integration load orders.
    public var dllOverrides: DLLOverrides
    /// Rosetta AVX advertising for this program; `nil` follows the bottle's setting.
    public var advertiseAVX: Bool?
    /// When MagicWine last started this program; see `BottleStore.recordLaunch`.
    public internal(set) var lastLaunchedAt: Date?
    /// Accumulated seconds from a program's start to the end of its processes; see
    /// `BottleStore.addPlayTime`.
    public internal(set) var playTime: TimeInterval
    /// Listed first in the app; see `BottleStore.setFavorite`.
    public internal(set) var isFavorite: Bool

    public init(id: UUID = UUID(), name: String, executablePath: String, arguments: [String] = [],
                workingDirectory: String? = nil, environment: [String: String] = [:],
                dllOverrides: DLLOverrides = .init(), advertiseAVX: Bool? = nil) {
        self.id = id
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.dllOverrides = dllOverrides
        self.advertiseAVX = advertiseAVX
        lastLaunchedAt = nil
        playTime = 0
        isFavorite = false
    }

    /// This record with `other`'s play history and favorite flag. Those change only through
    /// their own `BottleStore` transitions, so editors and general saves never overwrite them.
    func withLibraryMetadata(of other: WindowsProgram) -> WindowsProgram {
        var program = self
        program.lastLaunchedAt = other.lastLaunchedAt
        program.playTime = other.playTime
        program.isFavorite = other.isFavorite
        return program
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, executablePath, arguments, workingDirectory, environment, dllOverrides, advertiseAVX
        case lastLaunchedAt, playTime, isFavorite
    }

    /// Records saved before launch options or play history existed decode with empty options,
    /// no launches, and no favorite.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        executablePath = try container.decode(String.self, forKey: .executablePath)
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        dllOverrides = try container.decodeIfPresent(DLLOverrides.self, forKey: .dllOverrides) ?? .init()
        advertiseAVX = try container.decodeIfPresent(Bool.self, forKey: .advertiseAVX)
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
        playTime = try container.decodeIfPresent(TimeInterval.self, forKey: .playTime) ?? 0
        guard playTime >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .playTime, in: container,
                                                   debugDescription: "Play time must not be negative.")
        }
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }

    /// Empty options and history are omitted, so unedited programs keep their original shape.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(executablePath, forKey: .executablePath)
        if !arguments.isEmpty { try container.encode(arguments, forKey: .arguments) }
        try container.encodeIfPresent(workingDirectory, forKey: .workingDirectory)
        if !environment.isEmpty { try container.encode(environment, forKey: .environment) }
        if !dllOverrides.isEmpty { try container.encode(dllOverrides, forKey: .dllOverrides) }
        try container.encodeIfPresent(advertiseAVX, forKey: .advertiseAVX)
        try container.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)
        if playTime > 0 { try container.encode(playTime, forKey: .playTime) }
        if isFavorite { try container.encode(true, forKey: .isFavorite) }
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
    /// Launch switches that never touch the prefix; see `BottleStore.setCompatibility`.
    public internal(set) var compatibility: CompatibilityOptions
    /// Catalog dependencies MagicWine installed; see `WineRuntime.installDependencies`.
    public internal(set) var dependencies: [InstalledDependency]
    private var displayPreference: DisplayConfiguration?
    public var display: DisplayConfiguration {
        get { displayPreference ?? .init() }
        set { displayPreference = newValue }
    }
    internal var hasDisplayConfiguration: Bool { displayPreference != nil }

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date(), runtime: RuntimeDescriptor,
                isInitialized: Bool = false, programs: [WindowsProgram] = [], graphics: GraphicsConfiguration = .init(),
                display: DisplayConfiguration = .init(), msyncEnabled: Bool = true,
                compatibility: CompatibilityOptions = .init(), dependencies: [InstalledDependency] = []) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.runtime = runtime
        self.isInitialized = isInitialized
        self.programs = programs
        self.graphics = graphics
        self.displayPreference = display
        self.msyncEnabled = msyncEnabled
        self.compatibility = compatibility
        self.dependencies = dependencies
    }

    /// The `bottle.json` format this build writes. Records without `schemaVersion` are
    /// `legacySchemaVersion`; a record of a newer version is refused (`newerVersion`)
    /// rather than read and later saved without the fields this build does not know.
    public static let currentSchemaVersion = 1
    public static let legacySchemaVersion = 0

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id, name, createdAt, runtime, isInitialized, programs, graphics, msyncEnabled, compatibility, dependencies
        case displayPreference = "display"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = container.contains(.schemaVersion)
            ? try container.decode(Int.self, forKey: .schemaVersion) : Self.legacySchemaVersion
        guard version <= Self.currentSchemaVersion else {
            throw MagicWineError.newerVersion("This bottle was saved by a newer version of MagicWine (bottle format \(version); this version reads up to \(Self.currentSchemaVersion)).")
        }
        guard version >= Self.legacySchemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Invalid bottle format \(version).")
        }
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        runtime = try container.decode(RuntimeDescriptor.self, forKey: .runtime)
        isInitialized = try container.decode(Bool.self, forKey: .isInitialized)
        // A program's launch options, play history (`lastLaunchedAt`, `playTime`) and
        // favorite flag are omitted while empty in every version, so in legacy and current
        // records alike a missing one means none, zero, or not a favorite (`WindowsProgram`).
        programs = try container.decode([WindowsProgram].self, forKey: .programs)
        // Migration of legacy (version 0) records, which predate these fields: a missing
        // field takes what the record meant before it existed. Version 1 writes all of them
        // (display once one is chosen), so they are missing only from legacy records.
        // A present field must be valid (`null` too, except for the last two).
        func migrated<T: Decodable>(_ key: CodingKeys, _ legacy: T) throws -> T {
            container.contains(key) ? try container.decode(T.self, forKey: key) : legacy
        }
        // Standard graphics, MSync on (the managed runtime's default).
        graphics = try migrated(.graphics, GraphicsConfiguration())
        msyncEnabled = try migrated(.msyncEnabled, true)
        // No display yet: `BottleStore` adopts the prefix registry's (`hasDisplayConfiguration`).
        displayPreference = container.contains(.displayPreference)
            ? try container.decode(DisplayConfiguration.self, forKey: .displayPreference) : nil
        // Default launch switches and no recorded dependencies.
        compatibility = try container.decodeIfPresent(CompatibilityOptions.self, forKey: .compatibility) ?? .init()
        dependencies = try container.decodeIfPresent([InstalledDependency].self, forKey: .dependencies) ?? []
    }

    /// Always the current format; a display not chosen yet stays absent.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(runtime, forKey: .runtime)
        try container.encode(isInitialized, forKey: .isInitialized)
        try container.encode(programs, forKey: .programs)
        try container.encode(graphics, forKey: .graphics)
        try container.encode(msyncEnabled, forKey: .msyncEnabled)
        try container.encode(compatibility, forKey: .compatibility)
        try container.encode(dependencies, forKey: .dependencies)
        try container.encodeIfPresent(displayPreference, forKey: .displayPreference)
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

/// A completed bottle setup: the persisted bottle (now `isInitialized`) and Wine's log.
public struct BottleInitialization: Sendable {
    public let bottle: Bottle
    public let result: OperationResult

    public init(bottle: Bottle, result: OperationResult) {
        self.bottle = bottle
        self.result = result
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
