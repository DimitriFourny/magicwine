import Darwin
import Foundation

/// Offline registry access. Callers must hold the bottle's exclusive lock and ensure
/// Wine has stopped before applying changes; this helper never starts or stops Wine.
internal enum BottleDisplay {
    private static let desktop = #"Control Panel\\Desktop"#
    private static let driver = #"Software\\Wine\\Mac Driver"#
    private static let fonts = #"System\\ControlSet001\\Hardware Profiles\\Current\\Software\\Fonts"#

    static func existingConfiguration(prefix: URL) throws -> DisplayConfiguration? {
        try requirePrefix(prefix)
        let user = try Registry(read: prefix.appendingPathComponent("user.reg"))
        let retina = try user.retina()
        let userDPI = try user.dpi(section: desktop)
        let dpi: UInt32?
        if let userDPI {
            dpi = userDPI
        } else {
            dpi = try Registry(read: prefix.appendingPathComponent("system.reg")).dpi(section: fonts)
        }
        guard retina != nil || (dpi != nil && dpi != 96) else { return nil }
        return DisplayConfiguration(retinaEnabled: retina ?? false, dpi: dpi ?? 96)
    }

    static func needsUpdate(_ configuration: DisplayConfiguration, prefix: URL) throws -> Bool {
        try requirePrefix(prefix)
        let user = try Registry(read: prefix.appendingPathComponent("user.reg"))
        let retina = try user.retina()
        let dpi = try user.dpi(section: desktop)
        return retina != configuration.retinaEnabled || dpi != configuration.dpi
    }

    static func apply(_ configuration: DisplayConfiguration, prefix: URL) throws {
        try requirePrefix(prefix)
        let url = prefix.appendingPathComponent("user.reg")
        var user = try Registry(read: url)
        // Validate both values before editing either, including on a no-op launch.
        let retina = try user.retina()
        let dpi = try user.dpi(section: desktop)
        guard retina != configuration.retinaEnabled || dpi != configuration.dpi else { return }
        try user.set(section: driver, name: "RetinaMode", value: configuration.retinaEnabled ? "\"y\"" : "\"n\"")
        try user.set(section: desktop, name: "LogPixels", value: String(format: "dword:%08x", configuration.dpi))
        try requireRegularFileIfPresent(url)
        try Data(user.text.utf8).write(to: url, options: .atomic)
    }

    private struct Registry {
        var lines: [String]
        let newline: String
        var text: String { lines.joined(separator: "\n") }

        init(read url: URL) throws {
            guard try requireRegularFileIfPresent(url) else {
                lines = ["WINE REGISTRY Version 2", "", ""]
                newline = "\n"
                return
            }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8),
                  text.components(separatedBy: .newlines).first == "WINE REGISTRY Version 2" else {
                throw invalid("Invalid Wine registry at \(url.path)")
            }
            lines = text.components(separatedBy: "\n")
            newline = text.contains("\r\n") ? "\r\n" : "\n"
        }

        private func body(_ line: String) -> String {
            line.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func section(_ line: String) -> String? {
            let value = body(line)
            guard value.hasPrefix("["), let end = value.firstIndex(of: "]") else { return nil }
            return String(value[value.index(after: value.startIndex)..<end]).lowercased()
        }

        private func location(section target: String, name: String) throws -> (section: Int?, value: Int?) {
            let target = target.lowercased()
            let name = name.lowercased()
            var active = false
            var sectionIndex: Int?
            var valueIndex: Int?
            for (index, line) in lines.enumerated() {
                if let key = section(line) {
                    active = key == target
                    if active {
                        guard sectionIndex == nil else { throw invalid("Duplicate display registry section: \(target)") }
                        sectionIndex = index
                    }
                } else if active {
                    let value = body(line)
                    guard value.hasPrefix("\"") else { continue }
                    let rest = value.dropFirst()
                    guard let end = rest.firstIndex(of: "\"") else { continue }
                    guard rest[..<end].lowercased() == name else { continue }
                    guard valueIndex == nil else { throw invalid("Duplicate display registry value: \(name)") }
                    valueIndex = index
                }
            }
            return (sectionIndex, valueIndex)
        }

        private func value(section: String, name: String) throws -> String? {
            guard let index = try location(section: section, name: name).value else { return nil }
            let line = body(lines[index])
            let rest = line.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { throw invalid(name) }
            let suffix = rest[rest.index(after: end)...].trimmingCharacters(in: .whitespaces)
            guard suffix.hasPrefix("=") else { throw invalid("Malformed \(name)") }
            return suffix.dropFirst().trimmingCharacters(in: .whitespaces)
        }

        func retina() throws -> Bool? {
            guard let value = try value(section: driver, name: "RetinaMode") else { return nil }
            guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 3 else {
                throw invalid("RetinaMode must be a boolean string")
            }
            let contents = value.dropFirst().dropLast().lowercased()
            guard !contents.contains("\""), !contents.contains("\\") else { throw invalid("Malformed RetinaMode") }
            // Wine's IS_OPTION_TRUE uses the initial character, not the whole word.
            switch contents.first {
            case "y", "t", "1": return true
            case "n", "f", "0": return false
            default: throw invalid("Unrecognized RetinaMode")
            }
        }

        func dpi(section: String) throws -> UInt32? {
            guard let value = try value(section: section, name: "LogPixels") else { return nil }
            guard value.lowercased().hasPrefix("dword:") else { throw invalid("LogPixels must be a DWORD") }
            let digits = value.dropFirst(6)
            guard !digits.isEmpty, digits.count <= 8,
                  digits.allSatisfy({ $0.isASCII && $0.isHexDigit }),
                  let result = UInt32(digits, radix: 16), result > 0 else {
                throw invalid("Invalid LogPixels DWORD")
            }
            return result
        }

        mutating func set(section target: String, name: String, value: String) throws {
            let location = try location(section: target, name: name)
            let replacement = "\"\(name)\"=\(value)"
            if let index = location.value {
                lines[index] = replacement + (lines[index].hasSuffix("\r") ? "\r" : "")
            } else if let index = location.section {
                lines.insert(replacement + (newline == "\r\n" ? "\r" : ""), at: index + 1)
            } else {
                var updated = text
                if !updated.hasSuffix("\n") { updated += newline }
                updated += newline + "[\(target)]" + newline + replacement + newline
                lines = updated.components(separatedBy: "\n")
            }
        }
    }

    private static func requirePrefix(_ prefix: URL) throws {
        guard prefix.isFileURL, !prefix.pathComponents.contains("..") else { throw MagicWineError.invalidBottle }
        var status = stat()
        guard lstat(prefix.path, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw invalid("Display settings require a real bottle prefix directory: \(prefix.path)")
        }
    }

    @discardableResult
    private static func requireRegularFileIfPresent(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT { return false }
            throw invalid("Cannot inspect \(url.path): \(String(cString: strerror(errno)))")
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), status.st_nlink == 1 else {
            throw invalid("Display settings require an ordinary, unlinked registry file: \(url.path)")
        }
        return true
    }

    private static func invalid(_ detail: String) -> MagicWineError {
        .setup("Cannot read or update Wine display settings: \(detail)")
    }
}
