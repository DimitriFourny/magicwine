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

    static let notice = "MagicWine downloads original Gcenx public Wine builds, not a notarized MagicWine runtime. By confirming installation, you authorize use of unsigned Wine and removal of com.apple.quarantine only inside MagicWine's managed Wine Stable.app. MagicWine does not disable Gatekeeper or change system-wide security settings. The SHA-256 checksum verifies the archive matches the published checksum; it is not malware verification. Homebrew currently flags this distribution for Gatekeeper checks. Wine's optional Windows multimedia support requires the upstream universal GStreamer runtime (1.28.2 or newer) in /Library/Frameworks/GStreamer.framework; missing multimedia support is not a failure of basic Wine setup."

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
                try validateManagedDirectory(destination, paths: paths)
                let receiptURL = destination.appendingPathComponent("installation.json")
                guard try fileType(at: receiptURL) == mode_t(S_IFREG) else {
                    throw MagicWineError.setup("The cached Wine installation receipt is not an ordinary file.")
                }
                let receipt = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receiptURL))
                guard receipt["source"] == source.absoluteString,
                      receipt["sha256"]?.lowercased() == metadata.sha256.lowercased(),
                      receipt["version"] == metadata.version else {
                    throw MagicWineError.setup("The cached Wine installation receipt does not match the current publisher metadata.")
                }
                let removed = try removeQuarantine(from: destination, paths: paths)
                try append("Quarantine removal after user consent: \(destination.appendingPathComponent("Wine Stable.app").path); removed \(removed) com.apple.quarantine attributes.\n", to: logURL)
                try writeReceipt(receipt, at: destination)
                return destination.appendingPathComponent(relativeExecutable)
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
            try Task.checkCancellation()
            let removed = try removeQuarantine(from: extraction, paths: paths)
            try append("Quarantine removal after user consent: \(extraction.appendingPathComponent("Wine Stable.app").path); removed \(removed) com.apple.quarantine attributes.\n", to: logURL)
            try writeReceipt(["source": source.absoluteString, "sha256": checksum,
                              "version": metadata.version], at: extraction)
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

    private static func fileType(at url: URL) throws -> mode_t {
        var status = stat()
        guard url.path.withCString({ lstat($0, &status) }) == 0 else {
            let code = errno
            throw MagicWineError.setup("Cannot inspect Wine installation path \(url.path): \(String(cString: strerror(code)))")
        }
        return status.st_mode & mode_t(S_IFMT)
    }

    private static func validateManagedDirectory(_ directory: URL, paths: ApplicationPaths) throws {
        let managed = paths.runtimesDirectory.standardizedFileURL
        let target = directory.standardizedFileURL
        guard directory.isFileURL, target.path.hasPrefix(managed.path + "/"),
              try fileType(at: paths.root) == mode_t(S_IFDIR),
              try fileType(at: managed) == mode_t(S_IFDIR),
              target.resolvingSymlinksInPath().path.hasPrefix(managed.resolvingSymlinksInPath().path + "/") else {
            throw MagicWineError.setup("Quarantine removal is restricted to ordinary directories inside MagicWine's managed Runtimes directory.")
        }
        var current = target
        while current.path != managed.path {
            guard try fileType(at: current) == mode_t(S_IFDIR) else {
                throw MagicWineError.setup("The managed Wine installation contains a symbolic link or non-directory root: \(current.path)")
            }
            current.deleteLastPathComponent()
        }
    }

    private static func validateLayout(at root: URL) throws -> [URL] {
        let app = root.appendingPathComponent("Wine Stable.app", isDirectory: true)
        guard try fileType(at: app) == mode_t(S_IFDIR) else {
            throw MagicWineError.setup("Wine Stable.app must be an ordinary directory.")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: app,
              includingPropertiesForKeys: [], options: [], errorHandler: { _, error in
                  enumerationError = error
                  return false
              }) else {
            throw MagicWineError.setup("Cannot enumerate Wine Stable.app.")
        }
        // Validate the complete bundle before clearing any attributes.
        var targets = [app]
        for item in enumerator {
            guard let entry = item as? URL else {
                throw MagicWineError.setup("Wine Stable.app enumeration returned an invalid entry.")
            }
            let type = try fileType(at: entry)
            guard entry.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base) else {
                throw MagicWineError.setup("The Wine archive contains an escaping symbolic link: \(entry.path)")
            }
            if type == mode_t(S_IFLNK) {
                enumerator.skipDescendants()
            } else if type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) {
                targets.append(entry)
            } else {
                throw MagicWineError.setup("The Wine archive contains an unsupported filesystem entry: \(entry.path)")
            }
        }
        if let enumerationError { throw enumerationError }
        for name in ["wine", "wineserver"] {
            let executable = app.appendingPathComponent("Contents/Resources/wine/bin/\(name)")
            guard FileManager.default.isExecutableFile(atPath: executable.path),
                  executable.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(base),
                  try fileType(at: executable.resolvingSymlinksInPath()) == mode_t(S_IFREG) else {
                throw MagicWineError.setup("The Wine archive is missing its executable \(name).")
            }
        }
        return targets
    }

    static func removeQuarantine(from runtimeDirectory: URL, paths: ApplicationPaths) throws -> Int {
        try validateManagedDirectory(runtimeDirectory, paths: paths)
        let targets = try validateLayout(at: runtimeDirectory)
        let app = runtimeDirectory.appendingPathComponent("Wine Stable.app", isDirectory: true)
        let base = app.resolvingSymlinksInPath().standardizedFileURL.path
        var removed = 0
        for target in targets {
            let type = try fileType(at: target)
            let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
            guard (type == mode_t(S_IFREG) || type == mode_t(S_IFDIR)),
                  resolved == base || resolved.hasPrefix(base + "/") else {
                throw MagicWineError.setup("The Wine bundle changed during quarantine removal: \(target.path)")
            }
            let result = target.path.withCString { removexattr($0, "com.apple.quarantine", XATTR_NOFOLLOW) }
            if result == 0 {
                removed += 1
            } else {
                let code = errno
                guard code == ENOATTR else {
                    throw MagicWineError.setup("Cannot remove download quarantine from \(target.path): \(String(cString: strerror(code)))")
                }
            }
        }
        return removed
    }

    private static func writeReceipt(_ provenance: [String: String], at root: URL) throws {
        var receipt = provenance
        receipt["notice"] = notice
        receipt["unsignedConsent"] = "accepted"
        receipt["quarantine"] = "Removed com.apple.quarantine only from managed Wine Stable.app after user consent."
        let data = try JSONEncoder().encode(receipt)
        let receiptURL = root.appendingPathComponent("installation.json")
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            guard try fileType(at: receiptURL) == mode_t(S_IFREG) else {
                throw MagicWineError.setup("The Wine installation receipt is not an ordinary file.")
            }
            // Preserve the cached receipt's attributes outside the quarantine-removal scope.
            let handle = try FileHandle(forWritingTo: receiptURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
        } else {
            try data.write(to: receiptURL, options: .atomic)
        }
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
