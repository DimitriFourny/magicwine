import Darwin
import Foundation

/// Status of one catalog item in a bottle, from its post-install checks.
public struct DependencyStatus: Identifiable, Sendable {
    public var id: String { item.id }
    public let item: DependencyItem
    /// Human-readable failed checks; empty means installed.
    public let missing: [String]
    /// What MagicWine recorded installing; nil for items present for another reason.
    public let record: InstalledDependency?
    public var isInstalled: Bool { missing.isEmpty }
    /// Some checks pass, for example after an interrupted installation or a removed file.
    public var isPartial: Bool { !missing.isEmpty && missing.count < item.checks.count }
}

/// Recorded in `bottle.json` after a successful install. Status still comes from
/// the post-install checks, so a removed file shows as missing again.
public struct InstalledDependency: Codable, Hashable, Sendable {
    public let id: String
    public let version: String
    public let installedAt: Date

    public init(id: String, version: String, installedAt: Date) {
        self.id = id
        self.version = version
        self.installedAt = installedAt
    }
}

public enum DependencyProgress: Sendable {
    /// Delivered first with the summary log of this installation.
    case started(logURL: URL)
    case downloading(id: String, WineDownloadProgress)
    case verifying(id: String)
    case installing(id: String)
    case checking(id: String)
}

public struct DependencyInstallResult: Sendable {
    public let bottle: Bottle
    public let logURL: URL
    public let installed: [String]
    /// Requested items whose checks already passed; nothing was changed for them.
    public let alreadyPresent: [String]
}

/// One action of an item's installation, in order. Wine steps run through
/// `WineRuntime`; file placement happens only while the bottle is idle.
enum DependencyStep: Equatable, Sendable {
    case runInstaller(download: Int, arguments: [String])
    case extract(download: Int, members: [String])
    case place([DependencyFile])
    case importRegistry(String)
}

enum DependencyInstaller {
    static let fs = SecureFS(prefix: "Dependency installation: ")
    static let registryMaximum = 512 * 1_048_576

    /// Fetches a request into a temporary file owned by the caller; injectable for tests.
    typealias Fetch = @Sendable (URLRequest, (@Sendable (WineDownloadProgress) -> Void)?) async throws -> URL

    static let httpsFetch: Fetch = { request, progress in
        let (file, response) = try await RuntimeDownload.download(for: request, progress: progress)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url?.scheme == "https" else {
            try? FileManager.default.removeItem(at: file)
            throw MagicWineError.setup("The download of \(request.url?.lastPathComponent ?? "a dependency") returned an unsuccessful or insecure HTTP response (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        return file
    }

    // MARK: Planning

    static func steps(for item: DependencyItem) -> [DependencyStep] {
        var steps: [DependencyStep]
        switch item.method {
        case .silentInstaller(let arguments):
            steps = [.runInstaller(download: 0, arguments: arguments)]
        case .files(let files):
            steps = item.downloads.indices.compactMap { index in
                let members = files.filter { $0.download == index }.map(\.member)
                return members.isEmpty ? nil : .extract(download: index, members: members)
            }
            steps.append(.place(files))
        }
        if !item.registry.isEmpty { steps.append(.importRegistry(registryFile(item.registry))) }
        return steps
    }

    /// REGEDIT4 text for `reg import`, keys in first-use order.
    static func registryFile(_ values: [DependencyRegistryValue]) -> String {
        var keys: [String] = []
        var grouped: [String: [DependencyRegistryValue]] = [:]
        for value in values {
            let key = "\(value.hive.regName)\\\(value.key)"
            if grouped[key] == nil { keys.append(key) }
            grouped[key, default: []].append(value)
        }
        var text = "REGEDIT4\r\n"
        for key in keys {
            text += "\r\n[\(key)]\r\n"
            for value in grouped[key]! { text += "\(quoted(value.name))=\(quoted(value.value))\r\n" }
        }
        return text
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Download cache

    static func cacheDirectory(paths: ApplicationPaths) -> URL {
        paths.componentsDirectory.appendingPathComponent("dependencies", isDirectory: true)
    }

    /// `Components/dependencies/<item>-<sha-prefix>/<file>`, verified against its pin on every
    /// use. A cached file that no longer matches is replaced by a fresh download; anything
    /// that is not an ordinary MagicWine-owned file is refused.
    static func cachedDownload(_ download: DependencyDownload, of item: DependencyItem, paths: ApplicationPaths,
                               fetch: Fetch = httpsFetch,
                               progress: (@Sendable (WineDownloadProgress) -> Void)? = nil) async throws -> URL {
        try paths.prepare()
        try fs.requireDirectory(paths.componentsDirectory)
        let cache = cacheDirectory(paths: paths)
        if try !fs.exists(cache) {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try fs.requireDirectory(cache)
        let directory = cache.appendingPathComponent("\(item.id)-\(download.sha256.prefix(12))", isDirectory: true)
        let file = directory.appendingPathComponent(download.fileName)
        if try fs.exists(directory) {
            try fs.requireDirectory(directory)
            if try fs.exists(file), try await matches(file, download) { return file }
            // A partial or damaged entry inside the managed cache: replace it.
            try FileManager.default.removeItem(at: directory)
        }
        var request = URLRequest(url: download.url)
        request.timeoutInterval = 600
        let temporary = try await fetch(request, progress)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let stage = cache.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        let staged = stage.appendingPathComponent(download.fileName)
        try FileManager.default.moveItem(at: temporary, to: staged)
        try Task.checkCancellation()
        guard try await matches(staged, download) else {
            throw MagicWineError.setup("\(download.fileName) does not match its pinned SHA-256 and size. It was discarded and nothing was installed.")
        }
        if try !fs.publish(stage, to: directory) {
            // Another installer published the same pinned file first.
            guard try await matches(file, download) else {
                throw MagicWineError.setup("The cached \(download.fileName) at \(file.path) does not match its pinned SHA-256.")
            }
        }
        return file
    }

    private static func matches(_ file: URL, _ download: DependencyDownload) async throws -> Bool {
        let maximum = Int(download.size)
        let task = Task.detached(priority: .utility) { () throws -> Bool in
            guard try fs.status(file).st_size == download.size else { return false }
            return try fs.sha256(file, maximum: maximum) == download.sha256
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    // MARK: Extraction

    /// Extracts exactly `members` (plain names) of a verified cabinet with macOS bsdtar
    /// into `destination`, then verifies every extracted file against its pin.
    static func extract(_ files: [DependencyFile], from archive: URL, into destination: URL,
                        paths: ApplicationPaths) async throws -> [DependencyFile: URL] {
        let members = files.map(\.member)
        guard members.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\\") && $0 != "." && $0 != ".." }),
              Set(members).count == members.count else {
            throw MagicWineError.setup("Dependency archive members must be distinct plain file names.")
        }
        let listing = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-tf", archive.path], paths: paths,
                                                         name: "dependency-list", timeout: 60)
        // The first two lines are the operation's command header, not archive entries.
        let entries = try RuntimeInstallation.boundedLog(listing.logURL, maximum: 1_048_576)
            .components(separatedBy: "\n").dropFirst(2).filter { !$0.isEmpty }
        for member in members where entries.filter({ $0 == member }).count != 1 {
            throw MagicWineError.setup("\(archive.lastPathComponent) does not contain exactly one \(member).")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        _ = try await RuntimeInstallation.tool("/usr/bin/tar", arguments: ["-xf", archive.path, "-C", destination.path,
                "--no-same-owner", "--no-same-permissions", "--"] + members,
                paths: paths, name: "dependency-extract", timeout: 120)
        var result: [DependencyFile: URL] = [:]
        for file in files {
            let url = destination.appendingPathComponent(file.member)
            guard try fs.sha256(url, maximum: file.size) == file.sha256 else {
                throw MagicWineError.setup("\(file.member) from \(archive.lastPathComponent) does not match its pinned SHA-256.")
            }
            result[file] = url
        }
        return result
    }

    // MARK: Placement

    /// Copies verified files below `drive_c/windows`. Every destination is checked first:
    /// absent, a Wine builtin/placeholder DLL, or already the pinned file. Anything else is
    /// a user's file, so nothing is replaced. Files are staged beside their destination
    /// and renamed, so no destination is truncated or followed through a link.
    static func place(_ sources: [DependencyFile: URL], prefix: URL) throws {
        let windows = prefix.appendingPathComponent("drive_c/windows", isDirectory: true)
        for path in ["drive_c", "drive_c/windows"] {
            try fs.requireDirectory(prefix.appendingPathComponent(path, isDirectory: true))
        }
        let files = sources.keys.sorted { $0.destination < $1.destination }
        var pending: [DependencyFile] = []
        for file in files {
            let components = file.destination.split(separator: "/")
            guard components.count == 2, !components.contains(where: { $0 == ".." || $0 == "." }) else {
                throw MagicWineError.setup("Unsupported dependency destination: \(file.destination).")
            }
            let folder = windows.appendingPathComponent(String(components[0]), isDirectory: true)
            if file.fontName != nil, try !fs.exists(folder) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            try fs.requireDirectory(folder)
            let target = windows.appendingPathComponent(file.destination)
            guard let type = try fs.fileTypeIfPresent(target) else {
                pending.append(file)
                continue
            }
            guard type == mode_t(S_IFREG) else {
                throw MagicWineError.setup("\(target.path) is not an ordinary file. No dependency files were changed.")
            }
            if try fs.sha256(target, maximum: max(file.size, 64 * 1_048_576), allowsHardLinks: true) == file.sha256 { continue }
            guard let machine = file.machine, try wineMarker(target, machine: machine) != nil else {
                throw MagicWineError.setup("\(target.path) is a custom file that MagicWine did not install. It was left unchanged; remove it yourself to install this dependency.")
            }
            pending.append(file)
        }
        var staged: [(URL, URL)] = []
        defer { for (temporary, _) in staged { try? FileManager.default.removeItem(at: temporary) } }
        for file in pending {
            let target = windows.appendingPathComponent(file.destination)
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".magicwine-\(UUID().uuidString).tmp")
            try FileManager.default.copyItem(at: sources[file]!, to: temporary)
            staged.append((temporary, target))
            guard try fs.sha256(temporary, maximum: file.size) == file.sha256 else {
                throw MagicWineError.setup("A staged copy of \(file.member) changed. No dependency files were changed.")
            }
        }
        for (temporary, target) in staged {
            guard rename(temporary.path, target.path) == 0 else { throw fs.posixFailure("install", target) }
        }
        staged.removeAll()
    }

    static func isNativeDLL(_ url: URL, machine: UInt16) throws -> Bool {
        try wineMarker(url, machine: machine) == nil
    }

    /// The Wine marker of a PE DLL of `machine`; nil for a native DLL, an error for anything else.
    private static func wineMarker(_ url: URL, machine: UInt16) throws -> PEInspector.WineMarker? {
        let (handle, status) = try fs.open(url, maximum: 256 * 1_048_576, allowsHardLinks: true)
        defer { try? handle.close() }
        let header = try PEInspector.parse(size: Int(status.st_size), path: url.path, fs: fs) { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
        guard header.machine == machine, header.isDLL else {
            throw MagicWineError.setup("\(url.path) is not a \(machine == PEInspector.i386 ? "32" : "64")-bit DLL. It was left unchanged.")
        }
        return header.wineMarker
    }

    // MARK: Checks

    static func status(of item: DependencyItem, prefix: URL, record: InstalledDependency?) -> DependencyStatus {
        var registries: [DependencyRegistryValue.Hive: [String: [String: String]]] = [:]
        var missing: [String] = []
        let windows = prefix.appendingPathComponent("drive_c/windows", isDirectory: true)
        for check in item.checks {
            switch check {
            case .nativeDLL(let path, let machine):
                if (try? isNativeDLL(windows.appendingPathComponent(path), machine: machine)) != true {
                    missing.append("native \(path)")
                }
            case .file(let path):
                guard let status = try? fs.statusIfPresent(windows.appendingPathComponent(path)),
                      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_size > 0 else {
                    missing.append(path)
                    continue
                }
            case .registry(let value):
                if registries[value.hive] == nil {
                    registries[value.hive] = (try? registry(prefix.appendingPathComponent(value.hive.fileName))) ?? [:]
                }
                let saved = registries[value.hive]?[value.key.lowercased()]?[value.name.lowercased()]
                if saved != value.value { missing.append("\(value.hive.regName)\\\(value.key)\\\(value.name)") }
            }
        }
        return DependencyStatus(item: item, missing: missing, record: record)
    }

    /// String values of a Wine registry file by lowercased key and value name. Wine writes
    /// keys with doubled backslashes and values as `"name"="text"`; other types are skipped.
    static func registry(_ url: URL) throws -> [String: [String: String]] {
        let text = String(decoding: try fs.read(url, maximum: registryMaximum), as: UTF8.self)
        var result: [String: [String: String]] = [:]
        var key: String?
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                key = line.dropFirst().firstIndex(of: "]").map {
                    unescape(line[line.index(after: line.startIndex)..<$0]).lowercased()
                }
                continue
            }
            guard let key, line.hasPrefix("\""), let separator = line.range(of: "\"=\"") else { continue }
            let name = unescape(line[line.index(after: line.startIndex)..<separator.lowerBound]).lowercased()
            let rest = line[separator.upperBound...]
            guard rest.hasSuffix("\"") else { continue }
            result[key, default: [:]][name] = unescape(rest.dropLast())
        }
        return result
    }

    private static func unescape(_ text: Substring) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped || character != "\\" {
                result.append(character)
                escaped = false
            } else {
                escaped = true
            }
        }
        return result
    }
}
