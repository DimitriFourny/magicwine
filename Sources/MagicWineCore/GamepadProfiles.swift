import Foundation

public struct GamepadProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var mappings: [GamepadControl: GamepadControl]
    public var leftDeadZone: Double
    public var rightDeadZone: Double
    public var triggerSensitivity: Double
    public var responseCurve: GamepadResponseCurve
    public var vibrationStrength: Double

    public init(name: String = "Default") {
        id = UUID()
        self.name = name
        mappings = [:]
        leftDeadZone = 0.08
        rightDeadZone = 0.08
        triggerSensitivity = 1
        responseCurve = .linear
        vibrationStrength = 0.75
    }

    public static let defaults: [GamepadProfile] = {
        var standard = GamepadProfile()
        standard.id = UUID(uuidString: "A23E3700-CECD-4A96-8500-000000000001")!
        var racing = GamepadProfile(name: "Racing")
        racing.id = UUID(uuidString: "A23E3700-CECD-4A96-8500-000000000002")!
        racing.leftDeadZone = 0.04
        racing.responseCurve = .precision
        racing.vibrationStrength = 1
        var shooter = GamepadProfile(name: "Shooter")
        shooter.id = UUID(uuidString: "A23E3700-CECD-4A96-8500-000000000003")!
        shooter.rightDeadZone = 0.04
        shooter.triggerSensitivity = 1.5
        shooter.responseCurve = .precision
        shooter.vibrationStrength = 0.4
        return [standard, racing, shooter]
    }()

    public func mappedControl(for source: GamepadControl) -> GamepadControl {
        mappings[source] ?? source
    }

    public func validate() throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, name.count <= 96,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GamepadError.invalidConfiguration("Profile names must contain 1–96 characters and no control characters.")
        }
        guard mappings[.none] == nil else {
            throw GamepadError.invalidConfiguration("Unassigned is not a valid source control.")
        }
        for (label, value, range) in [
            ("Left dead zone", leftDeadZone, 0.0...0.4),
            ("Right dead zone", rightDeadZone, 0.0...0.4),
            ("Trigger sensitivity", triggerSensitivity, 0.5...2.0),
            ("Vibration strength", vibrationStrength, 0.0...1.0)
        ] {
            guard value.isFinite, range.contains(value) else {
                throw GamepadError.invalidConfiguration("\(label) must be between \(range.lowerBound) and \(range.upperBound).")
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, mappings, leftDeadZone, rightDeadZone, triggerSensitivity, responseCurve, vibrationStrength
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        let encodedMappings = try values.decode([String: GamepadControl].self, forKey: .mappings)
        mappings = [:]
        for (key, value) in encodedMappings {
            guard let control = GamepadControl(rawValue: key), control != .none else {
                throw GamepadError.invalidConfiguration("Unknown source control: \(key).")
            }
            mappings[control] = value
        }
        leftDeadZone = try values.decode(Double.self, forKey: .leftDeadZone)
        rightDeadZone = try values.decode(Double.self, forKey: .rightDeadZone)
        triggerSensitivity = try values.decode(Double.self, forKey: .triggerSensitivity)
        responseCurve = try values.decode(GamepadResponseCurve.self, forKey: .responseCurve)
        vibrationStrength = try values.decode(Double.self, forKey: .vibrationStrength)
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(Dictionary(uniqueKeysWithValues: mappings.map { ($0.key.rawValue, $0.value) }), forKey: .mappings)
        try values.encode(leftDeadZone, forKey: .leftDeadZone)
        try values.encode(rightDeadZone, forKey: .rightDeadZone)
        try values.encode(triggerSensitivity, forKey: .triggerSensitivity)
        try values.encode(responseCurve, forKey: .responseCurve)
        try values.encode(vibrationStrength, forKey: .vibrationStrength)
    }
}

public struct GamepadConfiguration: Codable, Equatable, Sendable {
    public var profiles: [GamepadProfile]
    public var activeProfileID: UUID

    public init() {
        profiles = GamepadProfile.defaults
        activeProfileID = profiles[0].id
    }

    /// Loaded and saved configurations are validated before this accessor is used.
    public var activeProfile: GamepadProfile {
        guard let profile = profiles.first(where: { $0.id == activeProfileID }) else {
            preconditionFailure("Validate a gamepad configuration before accessing its active profile.")
        }
        return profile
    }

    public func validate() throws {
        guard (1...64).contains(profiles.count) else {
            throw GamepadError.invalidConfiguration("Keep between 1 and 64 profiles.")
        }
        guard Set(profiles.map(\.id)).count == profiles.count else {
            throw GamepadError.invalidConfiguration("Profile identifiers must be unique.")
        }
        guard profiles.contains(where: { $0.id == activeProfileID }) else {
            throw GamepadError.invalidConfiguration("The selected profile does not exist.")
        }
        for profile in profiles { try profile.validate() }
    }
}

public struct GamepadProfileStore: Sendable {
    let configurationURL: URL
    static let didSave = Notification.Name("MagicWineGamepadProfilesDidSave")
    private static let maximumBytes = 1_048_576

    public init(paths: ApplicationPaths) {
        configurationURL = paths.root.appendingPathComponent("Gamepads", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    public func load() throws -> GamepadConfiguration {
        let data: Data
        do {
            data = try Self.readBounded(configurationURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return GamepadConfiguration()
        }
        let config = try JSONDecoder().decode(GamepadConfiguration.self, from: data)
        try config.validate()
        return config
    }

    public func save(_ config: GamepadConfiguration) throws {
        try config.validate()
        let data = try Self.encode(config)
        try FileManager.default.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configurationURL, options: .atomic)
        NotificationCenter.default.post(name: Self.didSave, object: configurationURL)
    }

    public func importProfile(from url: URL) throws -> GamepadProfile {
        var profile = try JSONDecoder().decode(GamepadProfile.self, from: Self.readBounded(url))
        try profile.validate()
        profile.id = UUID()
        return profile
    }

    public func exportProfile(_ profile: GamepadProfile, to url: URL) throws {
        try profile.validate()
        try Self.encode(profile).write(to: url, options: .atomic)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else {
            throw GamepadError.invalidConfiguration("The configuration exceeds the 1 MiB size limit.")
        }
        return data
    }

    private static func readBounded(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: maximumBytes + 1 - data.count), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= maximumBytes else {
                throw GamepadError.invalidConfiguration("The file exceeds the 1 MiB size limit.")
            }
        }
        return data
    }
}
