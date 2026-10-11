import Foundation
import CryptoKit
import Darwin

struct RuntimeInstallation {
    private struct Metadata: Decodable {
        let url: String
        let sha256: String
        let version: String
        let disabled: Bool?
        let disable_reason: String?
    }

    static let notice = "MagicWine downloads original Gcenx public Wine builds, not a notarized MagicWine runtime. Homebrew currently flags this distribution for Gatekeeper checks. MagicWine never disables Gatekeeper or removes quarantine. Wine's optional Windows multimedia support requires the upstream universal GStreamer runtime (1.28.2 or newer) in /Library/Frameworks/GStreamer.framework; missing multimedia support is not a failure of basic Wine setup."

    static func install(paths: ApplicationPaths) async throws -> URL {
        try paths.prepare()
        let logURL = paths.logsDirectory.appendingPathComponent("wine-install-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logURL.path, contents: Data((notice + "\n").utf8),
                                              attributes: [.posixPermissions: 0o600]) else {
            throw MagicWineError.setup("Cannot create installation log: \(logURL.path)")
        }
        let stage = paths.runtimesDirectory.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        do {
            let metadataURL = URL(string: "https://formulae.brew.sh/api/cask/wine-stable.json")!
            var request = URLRequest(url: metadataURL)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            try checkHTTP(response)
            guard data.count <= 1_048_576 else { throw MagicWineError.setup("Wine metadata is unexpectedly large.") }
            let metadata = try JSONDecoder().decode(Metadata.self, from: data)
            guard let source = URL(string: metadata.url), source.scheme == "https",
                  source.host?.lowercased() == "github.com", source.user == nil, source.password == nil,
                  source.port == nil, source.query == nil, source.fragment == nil,
                  source.path.hasPrefix("/Gcenx/macOS_Wine_builds/releases/download/"),
                  source.path.hasSuffix(".tar.xz"),
                  !source.pathComponents.contains(".."),
                  metadata.sha256.count == 64,
                  metadata.sha256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  !metadata.version.isEmpty,
                  metadata.version.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
                throw MagicWineError.setup("The maintained wine-stable metadata has an invalid publisher URL, version, or SHA-256 checksum.")
            }
            try append("Source: \(source.absoluteString)\nVersion: \(metadata.version)\nSHA-256: \(metadata.sha256)\nHomebrew disabled: \(metadata.disabled == true), reason: \(metadata.disable_reason ?? "none")\n", to: logURL)
            let destination = paths.runtimesDirectory.appendingPathComponent("wine-stable-\(metadata.version)-\(metadata.sha256.prefix(12))", isDirectory: true)
            let relativeExecutable = "Wine Stable.app/Contents/Resources/wine/bin/wine"
            if FileManager.default.fileExists(atPath: destination.path) {
                let existing = destination.appendingPathComponent(relativeExecutable)
                try validateLayout(at: destination)
                return existing
            }
            request = URLRequest(url: source)
            request.timeoutInterval = 600
            let (download, archiveResponse) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: download) }
            try checkHTTP(archiveResponse)
            let archive = stage.appendingPathComponent("wine.tar.xz")
            try FileManager.default.moveItem(at: download, to: archive)
            try Task.checkCancellation()
            let checksum = try await hash(archive)
            guard checksum == metadata.sha256.lowercased() else {
                throw MagicWineError.setup("Wine archive SHA-256 mismatch. No runtime was installed.")
            }
            let extraction = stage.appendingPathComponent("payload", isDirectory: true)
            try FileManager.default.createDirectory(at: extraction, withIntermediateDirectories: false)
            let listing = try await tool("/usr/bin/tar", arguments: ["-tf", archive.path], paths: paths, name: "archive-list", timeout: 60)
            let text = try boundedLog(listing.logURL, maximum: 16 * 1_048_576)
            // The first two lines are the operation's command header, not archive entries.
            let entries = text.components(separatedBy: "\n").dropFirst(2).filter { !$0.isEmpty }
            guard !entries.isEmpty, entries.allSatisfy({ entry in
                !entry.hasPrefix("/") && !entry.contains("\\") &&
                !entry.split(separator: "/").contains("..") &&
                (entry == "Wine Stable.app" || entry.hasPrefix("Wine Stable.app/"))
            }) else { throw MagicWineError.setup("The Wine archive contains unsafe or unexpected paths.") }
            // macOS bsdtar rejects traversal through symlinks and escaping hard links by default.
            _ = try await tool("/usr/bin/tar", arguments: ["-xf", archive.path, "-C", extraction.path,
                    "--no-same-owner", "--no-same-permissions"], paths: paths, name: "archive-extract", timeout: 180)
            try validateLayout(at: extraction)
            try Task.checkCancellation()
            let app = extraction.appendingPathComponent("Wine Stable.app", isDirectory: true)
            // URLSession is not a browser and does not reliably apply download quarantine.
            // Add provenance protection; never clear an existing quarantine attribute.
            let quarantine = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));MagicWine;"
            for url in [app, extraction.appendingPathComponent(relativeExecutable),
                        app.appendingPathComponent("Contents/Resources/wine/bin/wineserver")] {
                try addQuarantineIfAbsent(to: url, value: quarantine)
            }
            let receipt: [String: String] = ["source": source.absoluteString, "sha256": checksum,
                "version": metadata.version, "notice": notice]
            let receiptData = try JSONEncoder().encode(receipt)
            try receiptData.write(to: extraction.appendingPathComponent("installation.json"), options: .atomic)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: extraction, to: destination)
            try append("Published: \(destination.path)\n", to: logURL)
            return destination.appendingPathComponent(relativeExecutable)
        } catch is CancellationError {
            try? append("Installation cancelled.\n", to: logURL)
            throw CancellationError()
        } catch {
            try? append("Failure: \(error.localizedDescription)\n", to: logURL)
            throw MagicWineError.setup("Wine installation failed: \(error.localizedDescription)\nInstallation log: \(logURL.path)")
        }
    }

    static func tool(_ path: String, arguments: [String], paths: ApplicationPaths,
                     name: String, timeout: TimeInterval) async throws -> OperationResult {
        let operation = ProcessOperation(executable: URL(fileURLWithPath: path), arguments: arguments,
            environment: ProcessInfo.processInfo.environment, directory: nil,
            logURL: paths.logsDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).log"), timeout: timeout)
        do { return try await operation.run() }
        catch ProcessOperation.Interrupted.timedOut(let log) {
            throw MagicWineError.setup("\(name) timed out. Log: \(log.path)")
        }
    }

    static func boundedLog(_ url: URL, maximum: Int = 65_536) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw MagicWineError.setup("Log exceeds its inspection limit: \(url.path)") }
        return String(decoding: data, as: UTF8.self)
    }

    private static func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url?.scheme == "https" else {
            throw MagicWineError.setup("Wine download returned an unsuccessful or insecure HTTP response (\((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
    }

    private static func hash(_ url: URL) async throws -> String {
        let task = Task.detached(priority: .utility) {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            var bytes = 0
            while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                try Task.checkCancellation()
                bytes += data.count
                guard bytes <= 2_147_483_648 else { throw MagicWineError.setup("Wine archive exceeds the 2 GiB safety limit.") }
                digest.update(data: data)
            }
            return digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func validateLayout(at root: URL) throws {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let app = root.appendingPathComponent("Wine Stable.app")
        guard let enumerator = FileManager.default.enumerator(at: app,
              includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else {
            throw MagicWineError.setup("The archive is missing Wine Stable.app.")
        }
        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values.isSymbolicLink == true && !entry.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) {
                throw MagicWineError.setup("The Wine archive contains an escaping symbolic link: \(entry.path)")
            }
        }
        for name in ["wine", "wineserver"] {
            let executable = app.appendingPathComponent("Contents/Resources/wine/bin/\(name)")
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  executable.resolvingSymlinksInPath().path.hasPrefix(base) else {
                throw MagicWineError.setup("The Wine archive is missing its executable \(name).")
            }
        }
    }

    private static func addQuarantineIfAbsent(to url: URL, value: String) throws {
        let present = url.path.withCString { getxattr($0, "com.apple.quarantine", nil, 0, 0, 0) }
        if present >= 0 { return }
        guard errno == ENOATTR else { throw MagicWineError.setup("Cannot inspect download quarantine: \(url.path)") }
        let bytes = Array(value.utf8)
        let result = url.path.withCString { path in
            bytes.withUnsafeBytes { setxattr(path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE) }
        }
        guard result == 0 else { throw MagicWineError.setup("Cannot apply download quarantine: \(url.path)") }
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
