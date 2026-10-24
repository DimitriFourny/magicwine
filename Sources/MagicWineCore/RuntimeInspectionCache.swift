import Foundation

/// Successful `wine --version` inspections, persisted as `runtime-inspections.json` in
/// the library root so discovery does not run every candidate Wine on every start. An
/// entry is reused only while its canonical executable keeps the same device, inode,
/// size and modification time; a missing, unreadable, malformed or differently versioned
/// file is ignored. Failed inspections are never cached, so a Wine that macOS blocked
/// once is tried again. Only an optimization: write failures are ignored.
struct RuntimeInspectionCache {
    static let fileName = "runtime-inspections.json"
    private static let schema = 1
    private static let maximumSize = 1_048_576
    private static let fs = SecureFS(prefix: "Wine inspection cache: ")

    private struct Entry: Codable {
        let path: String
        let stamp: SecureFS.Stamp
        let version: String
    }

    private struct Stored: Codable {
        let schema: Int
        let runtimes: [Entry]
    }

    private let url: URL
    private var entries: [String: Entry] = [:]

    init(paths: ApplicationPaths) {
        url = paths.root.appendingPathComponent(Self.fileName)
        guard let data = try? Self.fs.read(url, maximum: Self.maximumSize),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.schema == Self.schema else { return }
        for entry in stored.runtimes where Self.isVersion(entry.version) { entries[entry.path] = entry }
    }

    /// Identity of `executable`'s current file, which must be its canonical path.
    static func stamp(of executable: URL) -> SecureFS.Stamp? {
        (try? fs.statusIfPresent(executable)).map(SecureFS.Stamp.init)
    }

    /// A line Wine prints for `--version`, such as `wine-11.0`.
    static func isVersion(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        return (lowercased.hasPrefix("wine-") || lowercased.hasPrefix("wine ")) && line.count <= 256
    }

    /// The version inspected for `executable` while its file had `stamp`.
    func version(of executable: URL, stamp: SecureFS.Stamp) -> String? {
        guard let entry = entries[executable.path], entry.stamp.sameContent(as: stamp) else { return nil }
        return entry.version
    }

    /// Adds one inspection to the file as it is now, dropping entries whose executable
    /// changed or disappeared, and replaces the file atomically.
    static func record(_ version: String, for executable: URL, stamp: SecureFS.Stamp, paths: ApplicationPaths) {
        var cache = RuntimeInspectionCache(paths: paths)
        cache.entries[executable.path] = Entry(path: executable.path, stamp: stamp, version: version)
        let current = cache.entries.values.filter { entry in
            entry.path == executable.path || Self.stamp(of: URL(fileURLWithPath: entry.path)).map(entry.stamp.sameContent) == true
        }
        let stored = Stored(schema: schema, runtimes: current.sorted { $0.path < $1.path })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: cache.url, options: .atomic)
    }
}
