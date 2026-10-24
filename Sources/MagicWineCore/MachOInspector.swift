import Foundation

/// Inspects, never dlopens, untrusted native code. Reads only the Mach-O header,
/// bounded load commands and, on request, the LC_SYMTAB symbol and string tables.
enum MachOInspector {
    static let x86_64: UInt32 = 0x01000007
    static let arm64: UInt32 = 0x0100000c

    struct Image: Sendable {
        let fileType: UInt32
        /// Highest LC_BUILD_VERSION/LC_VERSION_MIN_MACOSX minimum, encoded as xxxx.yy.zz.
        let minimumOS: UInt32?
        let dependencies: Set<String>
        let rpaths: Set<String>
        /// Public definitions only (N_EXT | N_SECT, excluding N_STAB and N_PEXT);
        /// empty unless requested.
        let exports: Set<String>
    }

    /// Inspects the x86_64 image at `url`. `universal` additionally accepts a fat
    /// file with exactly one x86_64 slice; otherwise only thin x86_64 is accepted.
    static func inspect(_ url: URL, fs: SecureFS, maximum: Int, universal: Bool, exports readExports: Bool) throws -> Image {
        let (handle, status) = try fs.open(url, maximum: maximum)
        defer { try? handle.close() }
        let fileSize = UInt64(status.st_size)
        func bytes(_ offset: UInt64, _ count: Int, within end: UInt64 = fileSize) throws -> Data {
            guard count >= 0, offset <= end, UInt64(count) <= end - offset else {
                throw fs.integrity("Truncated Mach-O data: \(url.path).")
            }
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw fs.integrity("Mach-O changed during inspection: \(url.path).") }
            return data
        }
        var slice: UInt64 = 0
        var sliceEnd = fileSize
        let magic = try bytes(0, 8)
        if universal, word(magic, 0, bigEndian: true) == 0xcafebabe {
            let count = Int(word(magic, 4, bigEndian: true))
            guard (1...16).contains(count) else { throw fs.integrity("Invalid universal Mach-O architecture table: \(url.path).") }
            let table = try bytes(8, count * 20)
            var found = false
            for index in 0..<count where word(table, index * 20, bigEndian: true) == x86_64 {
                guard !found else { throw fs.integrity("Duplicate x86_64 Mach-O slice: \(url.path).") }
                found = true
                slice = UInt64(word(table, index * 20 + 8, bigEndian: true))
                sliceEnd = UInt64(word(table, index * 20 + 12, bigEndian: true))
            }
            guard found, slice <= fileSize, sliceEnd <= fileSize - slice else {
                throw fs.integrity("No valid x86_64 Mach-O slice: \(url.path).")
            }
            sliceEnd += slice
        }
        let header = try bytes(slice, 32, within: sliceEnd)
        guard word(header, 0) == 0xfeedfacf, word(header, 4) == x86_64 else {
            throw fs.integrity("Expected \(universal ? "an" : "a thin") x86_64 Mach-O image: \(url.path).")
        }
        let count = Int(word(header, 16)), size = Int(word(header, 20))
        guard count > 0, count <= 4096, size >= count * 8, size <= 1_048_576 else {
            throw fs.integrity("Invalid Mach-O load command bounds: \(url.path).")
        }
        let commands = try bytes(slice + 32, size, within: sliceEnd)
        func string(_ data: Data, _ offset: Int, _ end: Int) throws -> String {
            guard offset >= 0, offset < end, end <= data.count,
                  let zero = data[offset..<end].firstIndex(of: 0),
                  let value = String(data: data[offset..<zero], encoding: .utf8) else {
                throw fs.integrity("Malformed Mach-O string: \(url.path).")
            }
            return value
        }
        var cursor = 0
        var dependencies = Set<String>(), rpaths = Set<String>()
        var minimumOS: UInt32?
        var symbols: (offset: UInt64, count: Int, strings: UInt64, stringSize: Int)?
        for _ in 0..<count {
            guard cursor <= size - 8 else { throw fs.integrity("Truncated Mach-O load command: \(url.path).") }
            let command = word(commands, cursor), length = Int(word(commands, cursor + 4))
            guard length >= 8, length % 8 == 0, length <= size - cursor else {
                throw fs.integrity("Invalid Mach-O load command size: \(url.path).")
            }
            switch command {
            case 0x0c, 0x80000018, 0x8000001f: // LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB
                guard length >= 24 else { throw fs.integrity("Truncated Mach-O dependency command: \(url.path).") }
                let offset = Int(word(commands, cursor + 8))
                guard offset >= 24, offset < length else { throw fs.integrity("Invalid Mach-O dependency name: \(url.path).") }
                dependencies.insert(try string(commands, cursor + offset, cursor + length))
            case 0x8000001c: // LC_RPATH
                guard length >= 16 else { throw fs.integrity("Truncated Mach-O rpath: \(url.path).") }
                let offset = Int(word(commands, cursor + 8))
                guard offset >= 12, offset < length else { throw fs.integrity("Invalid Mach-O rpath name: \(url.path).") }
                rpaths.insert(try string(commands, cursor + offset, cursor + length))
            case 0x32: // LC_BUILD_VERSION
                guard length >= 24, word(commands, cursor + 8) == 1 else {
                    throw fs.integrity("Expected a macOS Mach-O build target: \(url.path).")
                }
                minimumOS = max(minimumOS ?? 0, word(commands, cursor + 12))
            case 0x24: // LC_VERSION_MIN_MACOSX
                guard length >= 16 else { throw fs.integrity("Truncated Mach-O deployment target: \(url.path).") }
                minimumOS = max(minimumOS ?? 0, word(commands, cursor + 8))
            case 2: // LC_SYMTAB
                guard length == 24, symbols == nil else { throw fs.integrity("Invalid Mach-O symbol-table command: \(url.path).") }
                symbols = (UInt64(word(commands, cursor + 8)), Int(word(commands, cursor + 12)),
                           UInt64(word(commands, cursor + 16)), Int(word(commands, cursor + 20)))
            default: break
            }
            cursor += length
        }
        guard cursor == size else { throw fs.integrity("Unexpected trailing Mach-O load command data: \(url.path).") }
        var exports = Set<String>()
        if readExports, let symbols {
            guard symbols.count <= 1_048_576, symbols.stringSize <= 16 * 1_048_576 else {
                throw fs.integrity("Mach-O symbols exceed inspection bounds: \(url.path).")
            }
            // Symbol and string offsets are relative to the start of the slice.
            let table = try bytes(slice + symbols.offset, symbols.count * 16, within: sliceEnd)
            let strings = try bytes(slice + symbols.strings, symbols.stringSize, within: sliceEnd)
            for index in 0..<symbols.count {
                let type = table[index * 16 + 4]
                guard type & 0xe0 == 0, type & 0x10 == 0, type & 0x0f == 0x0f else { continue }
                exports.insert(try string(strings, Int(word(table, index * 16)), strings.count))
            }
        }
        return Image(fileType: word(header, 12), minimumOS: minimumOS,
                     dependencies: dependencies, rpaths: rpaths, exports: exports)
    }

    /// CPU types named by a thin (either byte order, 32/64-bit) or universal
    /// (fat/fat64, either byte order) header within `prefix`, without validating
    /// the rest of the file. Nil when `prefix` is not a complete Mach-O header table.
    static func cpuTypes(in prefix: Data) -> [UInt32]? {
        guard prefix.count >= 8 else { return nil }
        let magic = word(prefix, 0, bigEndian: true)
        switch magic {
        case 0xcffaedfe, 0xcefaedfe: return [word(prefix, 4)]
        case 0xfeedfacf, 0xfeedface: return [word(prefix, 4, bigEndian: true)]
        case 0xcafebabe, 0xcafebabf, 0xbebafeca, 0xbfbafeca:
            let bigEndian = magic == 0xcafebabe || magic == 0xcafebabf
            let stride = magic == 0xcafebabf || magic == 0xbfbafeca ? 32 : 20
            let count = Int(word(prefix, 4, bigEndian: bigEndian))
            guard count <= (prefix.count - 8) / stride else { return nil }
            return (0..<count).map { word(prefix, 8 + $0 * stride, bigEndian: bigEndian) }
        default: return nil
        }
    }

    private static func word(_ data: Data, _ offset: Int, bigEndian: Bool = false) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, index in
            value | UInt32(data[data.startIndex + offset + index]) << (8 * (bigEndian ? 3 - index : index))
        }
    }
}
