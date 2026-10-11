import Foundation

/// Each bottle is independently persisted; names never become filesystem paths.
public actor BottleStore {
    private let paths: ApplicationPaths
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: ApplicationPaths) {
        self.paths = paths
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public nonisolated func prefixURL(for bottle: Bottle) -> URL {
        paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
            .appendingPathComponent("prefix", isDirectory: true)
    }

    public func list() throws -> [Bottle] {
        try paths.prepare()
        let directories = try FileManager.default.contentsOfDirectory(
            at: paths.bottlesDirectory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        var bottles: [Bottle] = []
        for directory in directories {
            guard let id = UUID(uuidString: directory.lastPathComponent) else { continue }
            let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { continue }
            let bottle = try decoder.decode(Bottle.self, from: Data(contentsOf: directory.appendingPathComponent("bottle.json")))
            guard bottle.id == id else { throw MagicWineError.invalidBottle }
            bottles.append(bottle)
        }
        return bottles.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id.uuidString < $1.id.uuidString : comparison == .orderedAscending
        }
    }

    public func create(name: String, runtime: RuntimeDescriptor) throws -> Bottle {
        let name = try validatedName(name)
        try paths.prepare()
        let bottle = Bottle(name: name, runtime: runtime)
        let directory = directoryURL(for: bottle)
        try FileManager.default.createDirectory(at: prefixURL(for: bottle), withIntermediateDirectories: true)
        do {
            try encoder.encode(bottle).write(to: directory.appendingPathComponent("bottle.json"), options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return bottle
    }

    public func save(_ bottle: Bottle) throws {
        _ = try validatedName(bottle.name)
        try validateOwnership(bottle)
        try encoder.encode(bottle).write(to: directoryURL(for: bottle).appendingPathComponent("bottle.json"), options: [.atomic])
    }

    public func delete(_ bottle: Bottle) throws {
        try validateOwnership(bottle)
        try FileManager.default.trashItem(at: directoryURL(for: bottle), resultingItemURL: nil)
    }

    public func registerProgram(in bottle: Bottle, executableURL: URL, name: String? = nil) throws -> Bottle {
        var current = try load(bottle)
        let executable = executableURL.standardizedFileURL.resolvingSymlinksInPath()
        let ext = executable.pathExtension.lowercased()
        let attributes = try? executable.resourceValues(forKeys: [.isRegularFileKey])
        guard executable.isFileURL, ["exe", "lnk"].contains(ext), attributes?.isRegularFile == true else {
            throw MagicWineError.invalidProgram(executable.path)
        }
        guard !current.programs.contains(where: { $0.executablePath == executable.path }) else { return current }
        let programName = try validatedName(name ?? executable.deletingPathExtension().lastPathComponent)
        current.programs.append(WindowsProgram(name: programName, executablePath: executable.path))
        current.programs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try save(current)
        return current
    }

    public func removeProgram(id: UUID, in bottle: Bottle) throws -> Bottle {
        var current = try load(bottle)
        current.programs.removeAll { $0.id == id }
        try save(current)
        return current
    }

    public func discoverPrograms(in bottle: Bottle) throws -> Bottle {
        var current = try load(bottle)
        let drive = prefixURL(for: bottle).appendingPathComponent("drive_c", isDirectory: true)
        let roots = [drive.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs"),
                     drive.appendingPathComponent("users")]
        var known = Set(current.programs.map(\.executablePath))
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in false }) else { continue }
            for case let candidate as URL in enumerator {
                let attributes = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                if attributes.isSymbolicLink == true {
                    if attributes.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if root.lastPathComponent == "users", attributes.isDirectory == true {
                    let components = candidate.pathComponents
                    let relativeDepth = components.count - root.pathComponents.count
                    // At each user's root, only Desktop and AppData can contain launchers.
                    if relativeDepth == 2, !["Desktop", "AppData"].contains(candidate.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    if relativeDepth == 3, candidate.deletingLastPathComponent().lastPathComponent == "AppData",
                       candidate.lastPathComponent != "Roaming" { enumerator.skipDescendants() }
                }
                guard attributes.isRegularFile == true, candidate.pathExtension.lowercased() == "lnk" else { continue }
                let relative = candidate.path.replacingOccurrences(of: root.path + "/", with: "")
                if root.lastPathComponent == "users",
                   !relative.contains("/Desktop/"), !relative.contains("/Start Menu/Programs/") { continue }
                let name = candidate.deletingPathExtension().lastPathComponent
                if name.localizedCaseInsensitiveContains("uninstall") { continue }
                guard known.insert(candidate.path).inserted else { continue }
                current.programs.append(WindowsProgram(name: name, executablePath: candidate.path))
            }
        }
        current.programs.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try save(current)
        return current
    }

    public func settings() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: paths.settingsURL.path) else { return AppSettings() }
        return try decoder.decode(AppSettings.self, from: Data(contentsOf: paths.settingsURL))
    }

    public func saveSettings(_ settings: AppSettings) throws {
        try paths.prepare()
        try encoder.encode(settings).write(to: paths.settingsURL, options: [.atomic])
    }

    private func directoryURL(for bottle: Bottle) -> URL {
        paths.bottlesDirectory.appendingPathComponent(bottle.id.uuidString, isDirectory: true)
    }

    private func validatedName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw MagicWineError.invalidName }
        return trimmed
    }

    private func validateOwnership(_ bottle: Bottle) throws {
        let directory = directoryURL(for: bottle)
        let attributes = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attributes.isDirectory == true, attributes.isSymbolicLink != true,
              directory.resolvingSymlinksInPath().deletingLastPathComponent() == paths.bottlesDirectory.resolvingSymlinksInPath() else {
            throw MagicWineError.invalidBottle
        }
        let metadata = directory.appendingPathComponent("bottle.json")
        let metadataAttributes = try metadata.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard metadataAttributes.isSymbolicLink != true else { throw MagicWineError.invalidBottle }
        let current = try decoder.decode(Bottle.self, from: Data(contentsOf: metadata))
        guard current.id == bottle.id else { throw MagicWineError.invalidBottle }
    }

    private func load(_ bottle: Bottle) throws -> Bottle {
        try validateOwnership(bottle)
        return try decoder.decode(Bottle.self, from: Data(contentsOf: directoryURL(for: bottle).appendingPathComponent("bottle.json")))
    }
}
