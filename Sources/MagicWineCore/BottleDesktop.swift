import Darwin
import Foundation

internal enum BottleDesktop {
    /// Call under the bottle lock, before starting Wine or scanning its Desktop.
    static func prepare(prefix: URL) throws {
        guard prefix.isFileURL else { throw MagicWineError.invalidBottle }
        try requireDirectory(prefix)
        let drive = prefix.appendingPathComponent("drive_c")
        try ensureDirectory(drive)
        let users = drive.appendingPathComponent("users")
        try ensureDirectory(users)

        // Wine 11's set_home_dir uses USER, falling back to the Unix account name.
        // It strips Unix and Windows path prefixes before publishing WINEUSERNAME.
        let name = try userName(environment: ProcessInfo.processInfo.environment)
        let current = users.appendingPathComponent(name)
        try ensureDirectory(current)
        let profiles = try FileManager.default.contentsOfDirectory(
            at: users, includingPropertiesForKeys: nil)
        for profile in profiles {
            let type = try fileType(profile)
            guard type != mode_t(S_IFLNK) else {
                throw unsafeDirectory(profile)
            }
            guard type == mode_t(S_IFDIR) else { continue }
            let desktop = profile.appendingPathComponent("Desktop")
            if try fileType(desktop) == mode_t(S_IFLNK) {
                // unlink removes the link itself, including a broken one. Never
                // enumerate, copy, move, or remove anything at its host target.
                guard unlink(desktop.path) == 0 else {
                    throw fileError("Cannot remove Desktop link at \(desktop.path)")
                }
            }
            // shell32/shellpath.c checks PathFileExistsW before create_link, so
            // an existing real directory survives both initialization and -u.
            try ensureDirectory(desktop)
        }
    }

    static func userName(environment: [String: String]) throws -> String {
        let account: String
        if let user = environment["USER"] {
            account = user
        } else {
            var entry = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: 1024)
            while true {
                let (status, name) = buffer.withUnsafeMutableBufferPointer { storage in
                    let status = getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result)
                    return (status, status == 0 && result != nil ? String(cString: entry.pw_name) : nil)
                }
                if status == ERANGE {
                    buffer = [CChar](repeating: 0, count: buffer.count * 2)
                    continue
                }
                account = name ?? "wine"
                break
            }
        }
        var name = account[...]
        if let separator = name.lastIndex(of: "/") { name = name[name.index(after: separator)...] }
        if let separator = name.lastIndex(of: "\\") { name = name[name.index(after: separator)...] }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("\0") else {
            throw MagicWineError.setup("Wine's username must identify a local profile directory.")
        }
        return String(name)
    }

    private static func ensureDirectory(_ url: URL) throws {
        if try fileType(url) == nil {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        try requireDirectory(url)
    }

    private static func requireDirectory(_ url: URL) throws {
        guard try fileType(url) == mode_t(S_IFDIR) else { throw unsafeDirectory(url) }
    }

    private static func fileType(_ url: URL) throws -> mode_t? {
        var status = stat()
        if lstat(url.path, &status) == 0 { return status.st_mode & mode_t(S_IFMT) }
        if errno == ENOENT { return nil }
        throw fileError("Cannot inspect \(url.path)")
    }

    private static func unsafeDirectory(_ url: URL) -> MagicWineError {
        .setup("Bottle Desktop setup requires a real directory, not a symbolic link or file: \(url.path)")
    }

    private static func fileError(_ detail: String) -> MagicWineError {
        .setup("\(detail): \(String(cString: strerror(errno)))")
    }
}
