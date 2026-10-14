import Foundation

struct WindowsIconSource: Sendable {
    let url: URL
    let index: Int
}

/// Reads bounded local shortcut metadata; never invokes the Windows shell.
enum WindowsShortcut {
    private static let maximumSize = 1_048_576

    enum LaunchIdentity: Hashable {
        case file(URL)
        case internet(String)
        case command(target: URL, arguments: String, directory: URL, show: Int, options: Int)
    }

    static func launchIdentity(for url: URL, prefix: URL) -> LaunchIdentity {
        let fallback = LaunchIdentity.file(url.standardizedFileURL)
        guard isLocal(url), isLocal(prefix) else { return fallback }
        let resolver = Resolver(prefix: prefix, shortcut: url)
        guard let directory = resolver.canonical(url.deletingLastPathComponent()) else { return fallback }
        switch url.pathExtension.lowercased() {
        case "exe":
            guard let target = resolver.canonical(url), isRegularFile(target) else { return fallback }
            return .command(target: target, arguments: "", directory: directory, show: 1, options: 0)
        case "url":
            guard let data = contents(of: url), let shortcut = InternetShortcut(data: data),
                  let target = shortcut.target, shortcut.hasUnambiguousTarget,
                  !target.contains("\\"),
                  target.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
                  let scheme = URL(string: target)?.scheme, scheme.count > 1 else { return fallback }
            return .internet(target)
        case "lnk":
            guard let data = contents(of: url), let link = Link(data: data),
                  link.supportsLaunchIdentity else { return fallback }
            let working: URL
            if let path = link.workingDirectory, !path.isEmpty {
                guard let resolved = resolver.resolve(path, relativeTo: directory),
                      (try? resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return fallback }
                working = resolved
            } else {
                // WineRuntime starts shortcuts in their containing directory.
                working = directory
            }
            let path: String?
            if link.preferEnvironment {
                path = link.environmentTarget
            } else {
                path = link.target ?? link.environmentTarget ?? link.relativeTarget
            }
            guard let path, let target = resolver.resolve(path, relativeTo: working),
                  target.pathExtension.lowercased() == "exe", isRegularFile(target) else { return fallback }
            // Relative-only links can name different existing files from the two plausible bases.
            if link.target == nil, link.environmentTarget == nil,
               let alternate = resolver.resolve(path, relativeTo: directory), alternate != target { return fallback }
            return .command(target: target, arguments: link.arguments ?? "", directory: working,
                            show: link.showCommand, options: link.launchOptions)
        default:
            return fallback
        }
    }

    private static func isLocal(_ url: URL) -> Bool {
        url.isFileURL && [nil, "", "localhost"].contains(url.host)
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private static func contents(of url: URL) -> Data? {
        guard isLocal(url), isRegularFile(url), let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let data = try? file.read(upToCount: maximumSize + 1), data.count <= maximumSize else { return nil }
        return data
    }

    static func candidates(for shortcutURL: URL, prefix: URL) -> [WindowsIconSource] {
        guard isLocal(prefix), let data = contents(of: shortcutURL) else { return [] }
        let resolver = Resolver(prefix: prefix, shortcut: shortcutURL)
        if shortcutURL.pathExtension.lowercased() == "url" {
            guard let shortcut = InternetShortcut(data: data), let icon = shortcut.icon,
                  let url = resolver.resolve(icon, relativeTo: shortcutURL.deletingLastPathComponent()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return [] }
            return [WindowsIconSource(url: url, index: shortcut.index)]
        }
        guard let link = Link(data: data) else { return [] }
        let working = link.workingDirectory.flatMap { resolver.resolve($0, relativeTo: nil) }
        var result: [WindowsIconSource] = []
        func append(_ path: String?, index: Int) {
            guard let path else { return }
            // A relative field can be relative to the working directory or to the link itself.
            let bases = working.map { [$0, shortcutURL.deletingLastPathComponent()] }
                ?? [shortcutURL.deletingLastPathComponent()]
            for base in bases {
                guard let url = resolver.resolve(path, relativeTo: base),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                if !result.contains(where: { $0.url == url && $0.index == index }) {
                    result.append(WindowsIconSource(url: url, index: index))
                }
            }
        }
        append(link.icon, index: link.iconIndex)
        append(link.environmentIcon, index: link.iconIndex)
        if link.preferEnvironment { append(link.environmentTarget, index: 0) }
        append(link.target, index: 0)
        if !link.preferEnvironment { append(link.environmentTarget, index: 0) }
        append(link.relativeTarget, index: 0)
        return result
    }

    private struct InternetShortcut {
        let icon: String?
        let index: Int
        let target: String?
        let hasUnambiguousTarget: Bool

        init?(data: Data) {
            let text: String?
            if data.starts(with: [0xff, 0xfe]) {
                guard data.count.isMultiple(of: 2) else { return nil }
                text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
            } else if data.starts(with: [0xfe, 0xff]) {
                guard data.count.isMultiple(of: 2) else { return nil }
                text = String(data: data.dropFirst(2), encoding: .utf16BigEndian)
            } else if data.starts(with: [0xef, 0xbb, 0xbf]) {
                text = String(data: data.dropFirst(3), encoding: .utf8)
            } else {
                text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            }
            guard let text, !text.contains("\0") else { return nil }
            var inSection = false
            var icon: String?
            var index: Int32?
            var hasValidIcon = true
            var target: String?
            var hasUnambiguousTarget = true
            for line in text.split(whereSeparator: \.isNewline) {
                let line = line.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
                if line.hasPrefix("[") {
                    inSection = line.caseInsensitiveCompare("[InternetShortcut]") == .orderedSame
                    continue
                }
                guard inSection, let equals = line.firstIndex(of: "=") else { continue }
                let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "url":
                    if target != nil || value.isEmpty { hasUnambiguousTarget = false }
                    target = value
                case "workingdirectory", "showcommand", "arguments":
                    // These nonstandard launch settings are not interpreted.
                    hasUnambiguousTarget = false
                case "iconfile":
                    if icon != nil || value.isEmpty { hasValidIcon = false }
                    icon = value
                case "iconindex":
                    if index != nil { hasValidIcon = false }
                    if let parsed = Int32(value) { index = parsed }
                    else { hasValidIcon = false }
                default:
                    break
                }
            }
            self.icon = hasValidIcon ? icon : nil
            self.index = Int(index ?? 0)
            self.target = target
            self.hasUnambiguousTarget = hasUnambiguousTarget
        }
    }

    private struct Bytes {
        let data: Data

        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset <= data.count - 2 else { return nil }
            return Int(data[offset]) | Int(data[offset + 1]) << 8
        }

        func u32(_ offset: Int) -> Int? {
            guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
            return low | high << 16
        }

        func string(_ start: Int, end: Int, unicode: Bool, terminated: Bool) -> String? {
            guard start >= 0, start <= end, end <= data.count else { return nil }
            var stop = start
            let stride = unicode ? 2 : 1
            while stop + stride <= end {
                if terminated && (unicode ? u16(stop) == 0 : data[stop] == 0) {
                    return decode(start, stop, unicode: unicode)
                }
                stop += stride
            }
            guard !terminated, stop == end else { return nil }
            return decode(start, stop, unicode: unicode)
        }

        private func decode(_ start: Int, _ end: Int, unicode: Bool) -> String? {
            let value = data.subdata(in: start..<end)
            return String(data: value, encoding: unicode ? .utf16LittleEndian : .windowsCP1252)
        }
    }

    private struct Link {
        var icon: String?
        var environmentIcon: String?
        var target: String?
        var environmentTarget: String?
        var relativeTarget: String?
        var workingDirectory: String?
        var arguments: String?
        var supportsLaunchIdentity: Bool
        let showCommand: Int
        let launchOptions: Int
        let iconIndex: Int
        let preferEnvironment: Bool

        init?(data: Data) {
            let bytes = Bytes(data: data)
            let clsid: [UInt8] = [1, 0x14, 2, 0, 0, 0, 0, 0, 0xc0, 0, 0, 0, 0, 0, 0, 0x46]
            guard data.count >= 76, bytes.u32(0) == 76,
                  data.subdata(in: 4..<20) == Data(clsid),
                  let flags = bytes.u32(20), let index = bytes.u32(56),
                  let show = bytes.u32(60) else { return nil }
            iconIndex = Int(Int32(bitPattern: UInt32(index)))
            preferEnvironment = flags & 0x02000000 != 0
            // Only understood data flags, environment preference, RunAsUser and RunInSeparateProcess.
            // ForceNoLinkInfo, advertised/shim links and unknown launch behavior retain their own row.
            supportsLaunchIdentity = flags & ~0x020066ff == 0
            showCommand = show
            launchOptions = flags & 0x2400
            var cursor = 76
            if flags & 1 != 0 {
                guard let count = bytes.u16(cursor), count <= data.count - cursor - 2 else { return nil }
                let end = cursor + 2 + count
                var item = cursor + 2
                while item < end {
                    guard let size = bytes.u16(item), size <= end - item else {
                        supportsLaunchIdentity = false
                        break
                    }
                    if size == 0 { break }
                    guard size >= 2 else {
                        supportsLaunchIdentity = false
                        break
                    }
                    item += size
                }
                if item != end - 2 || bytes.u16(item) != 0 { supportsLaunchIdentity = false }
                cursor += 2 + count
            }
            if flags & 2 != 0 {
                guard let size = bytes.u32(cursor), size >= 28, size <= data.count - cursor,
                      let header = bytes.u32(cursor + 4), header >= 28, header <= size,
                      header == 28 || header >= 36,
                      let infoFlags = bytes.u32(cursor + 8) else { return nil }
                if infoFlags != 1 { supportsLaunchIdentity = false }
                let start = cursor
                let end = cursor + size
                func path(at field: Int, unicode: Bool) -> String? {
                    guard let offset = bytes.u32(start + field), offset >= header, offset < size else { return nil }
                    return bytes.string(start + offset, end: end, unicode: unicode, terminated: true)
                }
                if infoFlags & 1 != 0 {
                    if let volume = bytes.u32(start + 12), volume >= header, volume <= size - 16,
                       let volumeSize = bytes.u32(start + volume), volumeSize >= 16, volumeSize <= size - volume {
                        // The volume descriptor is bounded; target resolution itself uses the bottle drive map.
                    } else {
                        supportsLaunchIdentity = false
                    }
                    guard let ansiBase = path(at: 16, unicode: false),
                          let ansiSuffix = path(at: 24, unicode: false) else { return nil }
                    var base = ansiBase
                    var suffix = ansiSuffix
                    if header >= 36 {
                        if bytes.u32(start + 28) != 0 {
                            guard let value = path(at: 28, unicode: true) else { return nil }
                            base = value
                        }
                        if bytes.u32(start + 32) != 0 {
                            guard let value = path(at: 32, unicode: true) else { return nil }
                            suffix = value
                        }
                    }
                    // Some writers put the complete path in LocalBasePath, including the suffix.
                    let normalizedBase = base.replacingOccurrences(of: "/", with: "\\")
                    let normalizedSuffix = suffix.replacingOccurrences(of: "/", with: "\\")
                    if suffix.isEmpty || normalizedBase.lowercased().hasSuffix(normalizedSuffix.lowercased()) {
                        target = base
                    } else {
                        target = base + (base.hasSuffix("\\") || suffix.hasPrefix("\\") ? "" : "\\") + suffix
                    }
                }
                // CommonNetworkRelativeLink is deliberately not followed.
                cursor = end
            }
            let unicode = flags & 0x80 != 0
            for flag in [4, 8, 16, 32, 64] where flags & flag != 0 {
                guard let count = bytes.u16(cursor) else { return nil }
                cursor += 2
                let length = count * (unicode ? 2 : 1)
                guard length <= data.count - cursor,
                      let rawValue = bytes.string(cursor, end: cursor + length, unicode: unicode, terminated: false) else { return nil }
                // Wine includes a trailing NUL in some counted StringData fields.
                let value = rawValue.hasSuffix("\0") ? String(rawValue.dropLast()) : rawValue
                guard !value.contains("\0") else { return nil }
                switch flag {
                case 8: relativeTarget = value
                case 16: workingDirectory = value
                case 32: arguments = value
                case 64: icon = value
                default: break // Display names do not affect launch identity.
                }
                cursor += length
            }
            while cursor < data.count {
                guard let size = bytes.u32(cursor) else { return nil }
                if size == 0 {
                    // The terminal block must actually terminate the shortcut.
                    guard cursor + 4 == data.count else { return nil }
                    if flags & 0x200 != 0, environmentTarget == nil { supportsLaunchIdentity = false }
                    return
                }
                guard size >= 8, size <= data.count - cursor,
                      let signature = bytes.u32(cursor + 4) else { return nil }
                if signature == 0xa0000001 || signature == 0xa0000007 {
                    guard size == 788,
                          let ansi = bytes.string(cursor + 8, end: cursor + 268, unicode: false, terminated: true),
                          let wide = bytes.string(cursor + 268, end: cursor + 788, unicode: true, terminated: true) else { return nil }
                    let path = wide.isEmpty ? ansi : wide
                    if signature == 0xa0000001 {
                        if environmentTarget != nil { supportsLaunchIdentity = false }
                        environmentTarget = path
                    } else {
                        environmentIcon = path
                    }
                } else if signature != 0xa0000003 || size != 96 {
                    // Well-formed tracker blocks only describe file history. Other blocks can change launch semantics.
                    supportsLaunchIdentity = false
                }
                cursor += size
            }
            return nil // A complete Shell Link ends with a TerminalBlock.
        }
    }

    private struct Resolver {
        let prefix: URL
        let shortcut: URL

        func canonical(_ url: URL) -> URL? {
            existing(root: URL(fileURLWithPath: "/"), components: Array(url.pathComponents.dropFirst()))
        }

        func resolve(_ input: String, relativeTo base: URL?) -> URL? {
            guard let expanded = expand(input), !expanded.isEmpty else { return nil }
            var path = expanded
            if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
                path = String(path.dropFirst().dropLast())
            }
            path = path.replacingOccurrences(of: "\\", with: "/")
            guard !path.hasPrefix("//"), !path.contains("\0"), !path.contains("\"") else { return nil }
            let characters = Array(path.utf8)
            let root: URL
            let remainder: String
            if characters.count >= 2, characters[1] == 58 {
                guard (65...90).contains(characters[0]) || (97...122).contains(characters[0]),
                      characters.count >= 3, characters[2] == 47,
                      let drive = driveRoot(String(UnicodeScalar(characters[0])).lowercased()) else { return nil }
                root = drive
                remainder = String(path.dropFirst(3))
            } else if path.hasPrefix("/") {
                guard let drive = driveRoot("c") else { return nil }
                root = drive
                remainder = String(path.dropFirst())
            } else {
                root = base ?? shortcut.deletingLastPathComponent()
                remainder = path
            }
            guard !remainder.contains(":"), !remainder.contains("%") else { return nil }
            return existing(root: root, components: remainder.split(separator: "/").map(String.init))
        }

        private func driveRoot(_ drive: String) -> URL? {
            if let devices = existing(root: prefix, components: ["dosdevices"]),
               let mapped = existing(root: devices, components: [drive + ":"]) { return mapped }
            return drive == "c" ? existing(root: prefix, components: ["drive_c"]) : nil
        }

        private func existing(root: URL, components: [String], linkDepth: Int = 0) -> URL? {
            guard linkDepth < 16 else { return nil }
            let manager = FileManager.default
            guard !isNetwork(root) else { return nil }
            var url = root.standardizedFileURL.resolvingSymlinksInPath()
            for component in components {
                if component == "." { continue }
                if component == ".." { url.deleteLastPathComponent(); continue }
                guard !isNetwork(url),
                      let entries = try? manager.contentsOfDirectory(atPath: url.path) else { return nil }
                let match = entries.contains(component) ? component
                    : entries.sorted().first(where: { $0.caseInsensitiveCompare(component) == .orderedSame })
                guard let match else { return nil }
                url.appendPathComponent(match)
                // Read links before any operation that follows them, including Wine drive mappings.
                if let destination = try? manager.destinationOfSymbolicLink(atPath: url.path) {
                    guard !destination.hasPrefix("//"), !destination.hasPrefix("\\\\") else { return nil }
                    let resolved = destination.hasPrefix("/") ? URL(fileURLWithPath: destination)
                        : url.deletingLastPathComponent().appendingPathComponent(destination)
                    guard let local = existing(root: URL(fileURLWithPath: "/"),
                                               // Standardization rewrites /private/var to /var on macOS,
                                               // which would re-enter that symlink indefinitely.
                                               components: Array(resolved.pathComponents.dropFirst()),
                                               linkDepth: linkDepth + 1) else { return nil }
                    url = local
                }
            }
            guard !isNetwork(url), manager.fileExists(atPath: url.path) else { return nil }
            return url.standardizedFileURL
        }

        private func isNetwork(_ url: URL) -> Bool {
            let path = url.path
            if path.hasPrefix("/Volumes/"),
               (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == false { return true }
            return path == "/Network" || path.hasPrefix("/Network/") || path == "/net" || path.hasPrefix("/net/")
        }

        private func expand(_ input: String) -> String? {
            var output = ""
            var remaining = input[...]
            while let start = remaining.firstIndex(of: "%") {
                output += remaining[..<start]
                let after = remaining.index(after: start)
                guard let end = remaining[after...].firstIndex(of: "%"),
                      let replacement = environment(String(remaining[after..<end]).lowercased()) else { return nil }
                output += replacement
                remaining = remaining[remaining.index(after: end)...]
            }
            output += remaining
            return output
        }

        private func environment(_ name: String) -> String? {
            switch name {
            case "systemdrive", "homedrive": return "C:"
            case "systemroot", "windir": return "C:\\windows"
            case "programfiles", "programw6432": return "C:\\Program Files"
            case "programfiles(x86)": return "C:\\Program Files (x86)"
            case "commonprogramfiles", "commonprogramw6432": return "C:\\Program Files\\Common Files"
            case "commonprogramfiles(x86)": return "C:\\Program Files (x86)\\Common Files"
            case "programdata", "allusersprofile": return "C:\\ProgramData"
            case "userprofile", "appdata", "localappdata", "username", "homepath":
                guard let user = userName() else { return nil }
                switch name {
                case "username": return user
                case "homepath": return "\\users\\" + user
                case "appdata": return "C:\\users\\" + user + "\\AppData\\Roaming"
                case "localappdata": return "C:\\users\\" + user + "\\AppData\\Local"
                default: return "C:\\users\\" + user
                }
            default: return nil
            }
        }

        private func userName() -> String? {
            guard let drive = driveRoot("c"), let users = existing(root: drive, components: ["users"]) else { return nil }
            let components = shortcut.resolvingSymlinksInPath().pathComponents
            let root = users.pathComponents
            if components.starts(with: root), components.count > root.count { return components[root.count] }
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: users.path) else { return nil }
            let names = entries.filter {
                !["public", "default", "default user", "all users"].contains($0.lowercased()) && !$0.hasPrefix(".")
            }.sorted()
            if let current = names.first(where: { $0.caseInsensitiveCompare(NSUserName()) == .orderedSame }) { return current }
            return names.count == 1 ? names[0] : nil
        }
    }
}
