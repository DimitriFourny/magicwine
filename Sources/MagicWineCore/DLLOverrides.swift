import Foundation

/// Wine's per-DLL load order (`WINEDLLOVERRIDES`) as an ordered list of distinct DLL
/// names. Wine gives no defined winner for a name listed twice, so setting an existing
/// name replaces its mode in place: layering and serialization are deterministic.
public struct DLLOverrides: Hashable, Sendable {
    public enum Mode: String, CaseIterable, Hashable, Sendable {
        case native = "n"
        case builtin = "b"
        case nativeThenBuiltin = "n,b"
        case builtinThenNative = "b,n"
        /// Wine's empty mode: the DLL is not loaded at all.
        case disabled = ""

        public var displayName: String {
            switch self {
            case .native: "Native"
            case .builtin: "Builtin"
            case .nativeThenBuiltin: "Native, then builtin"
            case .builtinThenNative: "Builtin, then native"
            case .disabled: "Disabled"
            }
        }

        /// Accepts Wine's letters (`n`, `b`, `n,b`, `b,n`, empty) and the spelled-out
        /// `native`/`builtin`/`disabled` forms, case-insensitively.
        public init(parsing text: String) throws {
            let value = text.trimmingCharacters(in: .whitespaces).lowercased()
            if value.isEmpty || value == "disabled" {
                self = .disabled
                return
            }
            let tokens = value.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let letters = try tokens.map { token -> String in
                switch token {
                case "n", "native": return "n"
                case "b", "builtin": return "b"
                default: throw MagicWineError.invalidInput("Unknown DLL load order “\(text)”. Use n, b, n,b, b,n, or disabled.")
                }
            }
            guard let mode = Mode(rawValue: letters.joined(separator: ",")) else {
                throw MagicWineError.invalidInput("Unknown DLL load order “\(text)”. Use n, b, n,b, b,n, or disabled.")
            }
            self = mode
        }
    }

    public struct Entry: Hashable, Sendable {
        public let dll: String
        public var mode: Mode
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Parses Wine syntax such as `d3d9,d3d10core,d3d11=n;dxgi=b`. Empty segments are
    /// ignored (so `";" + value` concatenations parse); a later duplicate wins.
    public init(parsing text: String) throws {
        for segment in text.split(separator: ";") {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else {
                throw MagicWineError.invalidInput("DLL override “\(trimmed)” needs a load order, for example \(trimmed)=n,b.")
            }
            let mode = try Mode(parsing: String(trimmed[trimmed.index(after: separator)...]))
            let names = trimmed[..<separator].split(separator: ",", omittingEmptySubsequences: false)
            for name in names { try set(mode, for: String(name)) }
        }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public subscript(dll: String) -> Mode? {
        guard let name = try? Self.validatedName(dll) else { return nil }
        return entries.first { $0.dll == name }?.mode
    }

    /// Replaces an existing DLL's mode in place, or appends a new DLL.
    public mutating func set(_ mode: Mode, for dll: String) throws {
        let name = try Self.validatedName(dll)
        if let index = entries.firstIndex(where: { $0.dll == name }) {
            entries[index].mode = mode
        } else {
            entries.append(Entry(dll: name, mode: mode))
        }
    }

    public mutating func remove(_ dll: String) {
        guard let name = try? Self.validatedName(dll) else { return }
        entries.removeAll { $0.dll == name }
    }

    /// `other` is the higher layer: each of its DLLs wins over this one's.
    public func layered(with other: DLLOverrides) -> DLLOverrides {
        var result = self
        for entry in other.entries {
            if let index = result.entries.firstIndex(where: { $0.dll == entry.dll }) {
                result.entries[index].mode = entry.mode
            } else {
                result.entries.append(entry)
            }
        }
        return result
    }

    /// Wine syntax; adjacent DLLs with the same mode share one `a,b=mode` segment.
    public var serialized: String {
        var segments: [String] = []
        var names: [String] = []
        var current: Mode?
        for entry in entries {
            if entry.mode != current, let mode = current {
                segments.append(names.joined(separator: ",") + "=" + mode.rawValue)
                names.removeAll()
            }
            current = entry.mode
            names.append(entry.dll)
        }
        if let mode = current { segments.append(names.joined(separator: ",") + "=" + mode.rawValue) }
        return segments.joined(separator: ";")
    }

    /// Wine matches module base names case-insensitively and without `.dll`. Paths and
    /// separators are refused so one name can never smuggle in another override.
    public static func validatedName(_ dll: String) throws -> String {
        var name = dll.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".dll") { name.removeLast(4) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-+.")
        guard !name.isEmpty, name.count <= 64, name.first != ".", name.allSatisfy(allowed.contains) else {
            throw MagicWineError.invalidInput("“\(dll)” is not a DLL name. Use a module name such as d3d11 or xinput1_3, without a path.")
        }
        return name
    }
}

extension DLLOverrides: Codable {
    /// Stored as one Wine-syntax string, so `bottle.json` stays readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(parsing: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(serialized)
    }
}
