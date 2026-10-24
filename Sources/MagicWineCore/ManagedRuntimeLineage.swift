import Foundation

/// The MagicWine-managed Metal Wine runtimes of the pinned Wine archive. Each revision is
/// installed at `Runtimes/wine-<version>-<archive digest prefix>-<driver family>.<revision>/`
/// and differs from the others only by its Metal driver (`WineMetalBuildPins.componentID`,
/// for example `winemac-wine11.0-metal.7`). Membership follows the canonical executable
/// location, never a reported version string.
struct ManagedRuntimeLineage {
    private static let componentID = WineMetalBuildPins.componentID
    private static let revisionSeparator = componentID.lastIndex(of: ".")!
    /// The driver component without its revision, such as `winemac-wine11.0-metal`.
    static let driverFamily = String(componentID[..<revisionSeparator])
    /// The revision `RuntimeInstallation` installs; only it has MSync.
    static let currentRevision = Int(componentID[componentID.index(after: revisionSeparator)...])!
    /// Revisions MagicWine published earlier for the same archive. They still launch (with
    /// the Mono TLS correction) and a bottle pinned to one can switch to the current one.
    static let historicalRevisions = 1..<currentRevision
    private static let directoryStem =
        "wine-\(RuntimeInstallation.version)-\(RuntimeInstallation.archiveSHA256.prefix(12))-\(driverFamily)."

    static func directoryName(revision: Int) -> String { directoryStem + String(revision) }
    static var currentDirectoryName: String { directoryName(revision: currentRevision) }

    /// `wine-<version>-<12 lowercase hex digest>-<driver component>`: any managed runtime
    /// directory, including ones of earlier Wine archives outside this lineage.
    static func isManagedDirectoryName(_ name: String) -> Bool {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        return parts.count >= 4 && parts[0] == "wine" && !parts[1].isEmpty && !parts.last!.isEmpty &&
            parts.dropFirst(2).dropLast().contains { $0.count == 12 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase } }
    }

    private let runtimesDirectory: URL

    init(paths: ApplicationPaths) {
        runtimesDirectory = paths.runtimesDirectory
    }

    /// The driver revision of the managed runtime `executable` resolves to, or `nil` for
    /// custom Wine, any other file, and malformed revisions. A revision newer than
    /// `currentRevision` (installed by a newer MagicWine) is a member that is neither
    /// current nor upgradable.
    func revision(of executable: URL) -> Int? {
        // Resolved per call: resolution of the library path depends on what exists now.
        let root = Self.canonical(runtimesDirectory).path + "/"
        let path = Self.canonical(executable).path
        guard path.hasPrefix(root) else { return nil }
        let name = path.dropFirst(root.count).prefix { $0 != "/" }
        guard name.hasPrefix(Self.directoryStem) else { return nil }
        let text = name.dropFirst(Self.directoryStem.count)
        guard let revision = Int(text), revision > 0, String(revision) == text else { return nil }
        let expected = URL(fileURLWithPath: root).appendingPathComponent(String(name), isDirectory: true)
            .appendingPathComponent(RuntimeInstallation.relativeExecutable)
        return Self.canonical(expected).path == path ? revision : nil
    }

    /// Any revision: needs Mono's fallback TLS.
    func isManagedMetal(_ executable: URL) -> Bool { revision(of: executable) != nil }

    /// The runtime `RuntimeInstallation` installs today.
    func isCurrent(_ executable: URL) -> Bool { revision(of: executable) == Self.currentRevision }

    /// An earlier revision that can switch in place to the current one.
    func isUpgradable(_ executable: URL) -> Bool {
        revision(of: executable).map(Self.historicalRevisions.contains) ?? false
    }

    private static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
}
