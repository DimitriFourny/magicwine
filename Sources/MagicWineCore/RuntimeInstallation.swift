import Foundation
import CryptoKit
import Darwin

struct RuntimeInstallation {
    static let notice = "MagicWine downloads pinned Gcenx Wine 11.0_1 and includes source-built, open-source Wine driver, runtime modules, and a matching wineserver for MSync, DXMT, and D3DMetal support. This is not a notarized MagicWine runtime. By confirming installation, you authorize use of unsigned Wine and its bundled modules, and removal of com.apple.quarantine only inside the MagicWine-managed Wine Stable.app. MagicWine does not disable Gatekeeper or change system-wide security settings. SHA-256 checksums verify pinned contents, not malware safety. MSync is enabled by default and can be disabled per bottle. Standard graphics remains the default; Metal backends require a supported host, and D3DMetal additionally requires locally installed Apple libraries. Wine's optional Windows multimedia support requires the upstream universal GStreamer runtime (1.28.2 or newer) in /Library/Frameworks/GStreamer.framework; missing multimedia support is not a failure of basic Wine setup."

    static let source = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!
    static let archiveSHA256 = "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"
    static let version = "11.0_1"
    static let relativeExecutable = "Wine Stable.app/Contents/Resources/wine/bin/wine"

    static func install(paths: ApplicationPaths,
                        progress: (@Sendable (WineInstallationProgress) -> Void)? = nil) async throws -> URL {
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
            progress?(.preparing)
            try append("Source: \(source.absoluteString)\nVersion: \(version)\nSHA-256: \(archiveSHA256)\nDriver: \(WineMetalDriver.componentID)\n", to: logURL)
            let destination = destination(paths: paths)
            if FileManager.default.fileExists(atPath: destination.path) {
                progress?(.reusing)
                let removed = try reuseCachedRuntime(at: destination, paths: paths)
                try append("Quarantine removal after user consent: \(destination.appendingPathComponent("Wine Stable.app").path); removed \(removed) com.apple.quarantine attributes.\n", to: logURL)
                return destination.appendingPathComponent(relativeExecutable)
            }
            var request = URLRequest(url: source)
            request.timeoutInterval = 600
            let (download, archiveResponse) = try await RuntimeDownload.download(for: request, progress: progress.map { callback in
                { @Sendable update in callback(.downloading(update)) }
            })
            defer { try? FileManager.default.removeItem(at: download) }
            try checkHTTP(archiveResponse)
            let archive = stage.appendingPathComponent("wine.tar.xz")
            try FileManager.default.moveItem(at: download, to: archive)
            try Task.checkCancellation()
            progress?(.verifying)
            let checksum = try await hash(archive)
            guard checksum == archiveSHA256 else {
                throw MagicWineError.setup("Wine archive SHA-256 mismatch. No runtime was installed.")
            }
            progress?(.extracting)
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
            progress?(.preparing)
            // Validate containment before the driver installer writes into the fresh stage.
            try validateManagedDirectory(extraction, paths: paths)
            _ = try validateLayout(at: extraction)
            let executable = extraction.appendingPathComponent(relativeExecutable)
            try WineMetalDriver.install(at: executable)
            try DXMTInstallation.validateNativeRuntime(executable)
            let removed = try removeQuarantine(from: extraction, paths: paths)
            try append("Quarantine removal after user consent: \(extraction.appendingPathComponent("Wine Stable.app").path); removed \(removed) com.apple.quarantine attributes.\n", to: logURL)
            try writeReceipt(provenance, at: extraction)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: extraction, to: destination)
            try append("Published: \(destination.path)\n", to: logURL)
            return destination.appendingPathComponent(relativeExecutable)
        } catch is CancellationError {
            try? append("Installation cancelled.\n", to: logURL)
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                try? append("Installation cancelled.\n", to: logURL)
                throw CancellationError()
            }
            try? append("Failure: \(error.localizedDescription)\n", to: logURL)
            throw MagicWineError.setup("Wine installation failed: \(error.localizedDescription)\nInstallation log: \(logURL.path)")
        }
    }

    static func destination(paths: ApplicationPaths) -> URL {
        let name = "wine-\(version)-\(archiveSHA256.prefix(12))-\(WineMetalDriver.componentID)"
        return paths.runtimesDirectory.appendingPathComponent(name, isDirectory: true)
    }

    static let provenance = [
        "source": source.absoluteString, "sha256": archiveSHA256,
        "version": version, "driverComponentID": WineMetalDriver.componentID
    ]

    static func reuseCachedRuntime(at destination: URL, paths: ApplicationPaths) throws -> Int {
        let receipt = try validateCachedRuntime(at: destination, paths: paths)
        let removed = try removeQuarantine(from: destination, paths: paths)
        try writeReceipt(receipt, at: destination)
        return removed
    }

    /// Inspect an already installed runtime without changing download trust or files.
    @discardableResult
    static func validateCachedRuntime(at destination: URL, paths: ApplicationPaths) throws -> [String: String] {
        guard destination.standardizedFileURL == self.destination(paths: paths).standardizedFileURL else {
            throw MagicWineError.setup("The cached Wine installation path does not match the pinned runtime.")
        }
        try validateManagedDirectory(destination, paths: paths)
        _ = try validateLayout(at: destination)
        let receiptURL = destination.appendingPathComponent("installation.json")
        guard try fileType(at: receiptURL) == mode_t(S_IFREG) else {
            throw MagicWineError.setup("The cached Wine installation receipt is not an ordinary file.")
        }
        let receipt = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: receiptURL))
        guard receipt["source"] == source.absoluteString,
              receipt["sha256"] == archiveSHA256,
              receipt["version"] == version,
              receipt["driverComponentID"] == WineMetalDriver.componentID else {
            throw MagicWineError.setup("The cached Wine installation receipt does not match the pinned archive and driver.")
        }
        let executable = destination.appendingPathComponent(relativeExecutable)
        try WineMetalDriver.validate(at: executable)
        try DXMTInstallation.validateNativeRuntime(executable)
        return receipt
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
