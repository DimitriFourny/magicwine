import Foundation

/// The shared first stage of bundled component installers (DXVK, DXMT). Layout,
/// receipt, quarantine propagation and publication stay with each component.
enum BundledArchive {
    /// Copies `bundled` to `archive` inside a private stage, preserving its quarantine,
    /// verifies the pinned SHA-256 on a cancellable detached task, requires the exact
    /// member list via `validateMembers(paths, typeCharacters)` from `tar -tf`/`-tvf`,
    /// then extracts beside `archive` into `payload/` with bsdtar's default
    /// link/traversal protections. Returns the extraction directory.
    static func extract(_ bundled: URL, to archive: URL, sha256: String, maximum: Int, toolPrefix: String,
                        paths: ApplicationPaths, fs: SecureFS,
                        progress: (@Sendable (GraphicsSetupProgress) -> Void)?,
                        validateMembers: ([String], [Character]) throws -> Void) async throws -> URL {
        try FileManager.default.copyItem(at: bundled, to: archive)
        try fs.preserveQuarantine(from: bundled, to: archive)
        try Task.checkCancellation()
        let hashing = Task.detached(priority: .utility) { try fs.sha256(archive, maximum: maximum) }
        let checksum = try await withTaskCancellationHandler { try await hashing.value } onCancel: { hashing.cancel() }
        guard checksum == sha256 else { throw fs.integrity("Archive SHA-256 mismatch. No component was installed.") }
        try Task.checkCancellation()
        let listing = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-tf", archive.path],
            paths: paths, name: toolPrefix + "-archive-list", timeout: 60)
        let verbose = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-tvf", archive.path],
            paths: paths, name: toolPrefix + "-archive-types", timeout: 60)
        try validateMembers(logRows(listing.logURL), logRows(verbose.logURL).compactMap(\.first))
        try Task.checkCancellation()
        progress?(.installing)
        let extraction = archive.deletingLastPathComponent().appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
        // The member preflight additionally forbids every link and non-pinned member.
        _ = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-xf", archive.path,
            "-C", extraction.path, "--no-same-owner", "--no-same-permissions"],
            paths: paths, name: toolPrefix + "-archive-extract", timeout: 180)
        return extraction
    }

    /// The first two log lines are the operation's command header, not archive entries.
    private static func logRows(_ logURL: URL) throws -> [String] {
        try RuntimeInstallation.boundedLog(logURL, maximum: 1_048_576)
            .components(separatedBy: "\n").dropFirst(2).filter { !$0.isEmpty }
    }
}
