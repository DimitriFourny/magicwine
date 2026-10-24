import Foundation

/// Reads only PE/COFF headers of Windows DLLs; never loads or executes them.
enum PEInspector {
    static let i386: UInt16 = 0x014c
    static let amd64: UInt16 = 0x8664

    /// Wine writes one of these markers directly after the 64-byte DOS header of its own DLLs.
    enum WineMarker: CaseIterable {
        case builtin, placeholder
        var bytes: Data { Data((self == .builtin ? "Wine builtin DLL\0" : "Wine placeholder DLL\0").utf8) }
    }

    struct Header {
        let offset: Int
        let machine: UInt16
        let characteristics: UInt16
        let optionalHeaderSize: UInt16
        /// Nil when the image ends before the optional header's magic.
        let optionalHeaderMagic: UInt16?
        let wineMarker: WineMarker?
        var isDLL: Bool { characteristics & 0x2000 != 0 }
    }

    /// Validates a DLL file without reading it completely. `requiresOptionalHeader`
    /// demands a contained PE32 (i386) or PE32+ optional header; nonempty `markers`
    /// demand one of those Wine markers instead of a native replacement.
    static func validateDLL(_ url: URL, machine: UInt16, requiresOptionalHeader: Bool = true,
                            markers: [WineMarker] = [], fs: SecureFS, maximum: Int) throws {
        let (handle, status) = try fs.open(url, maximum: maximum)
        defer { try? handle.close() }
        let header = try parse(size: Int(status.st_size), path: url.path, fs: fs) { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
        try validate(header, size: Int(status.st_size), machine: machine, requiresOptionalHeader: requiresOptionalHeader,
                     markers: markers, path: url.path, fs: fs)
    }

    /// Validates an already bounded in-memory DLL image.
    static func validateDLL(_ data: Data, path: String, machine: UInt16, requiresOptionalHeader: Bool = true,
                            markers: [WineMarker] = [], fs: SecureFS) throws {
        let header = try parse(size: data.count, path: path, fs: fs) { offset, count in
            data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
        }
        try validate(header, size: data.count, machine: machine, requiresOptionalHeader: requiresOptionalHeader,
                     markers: markers, path: path, fs: fs)
    }

    /// `read(offset, count)` is only called within `size`; short reads are rejected.
    static func parse(size: Int, path: String, fs: SecureFS,
                      read: (_ offset: Int, _ count: Int) throws -> Data) throws -> Header {
        func word(_ data: Data, _ offset: Int) -> UInt16 {
            UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
        }
        guard size >= 64 else { throw fs.integrity("Not a PE image: \(path).") }
        let dos = try read(0, 64)
        guard dos.count == 64, word(dos, 0) == 0x5a4d else { throw fs.integrity("Not a PE image: \(path).") }
        let offset = Int(UInt32(word(dos, 60)) | UInt32(word(dos, 62)) << 16)
        guard offset >= 64, offset <= size - 24 else { throw fs.integrity("Invalid PE header offset: \(path).") }
        let coff = try read(offset, min(26, size - offset))
        guard coff.count >= 24, Array(coff.prefix(4)) == [0x50, 0x45, 0, 0] else {
            throw fs.integrity("Invalid PE signature: \(path).")
        }
        let stub = try read(64, min(21, size - 64))
        return Header(offset: offset, machine: word(coff, 4), characteristics: word(coff, 22),
                      optionalHeaderSize: word(coff, 20), optionalHeaderMagic: coff.count >= 26 ? word(coff, 24) : nil,
                      wineMarker: WineMarker.allCases.first { stub.starts(with: $0.bytes) })
    }

    private static func validate(_ header: Header, size: Int, machine: UInt16, requiresOptionalHeader: Bool,
                                 markers: [WineMarker], path: String, fs: SecureFS) throws {
        let nativeMagic: UInt16 = machine == i386 ? 0x010b : 0x020b
        guard header.machine == machine, header.isDLL,
              !requiresOptionalHeader || (header.optionalHeaderSize >= 2 &&
                header.offset + 24 + Int(header.optionalHeaderSize) <= size &&
                header.optionalHeaderMagic == nativeMagic) else {
            throw fs.integrity("The DLL has the wrong PE architecture or image type: \(path) (expected \(String(machine, radix: 16)), found \(String(header.machine, radix: 16))).")
        }
        if !markers.isEmpty {
            guard let marker = header.wineMarker, markers.contains(marker) else {
                throw fs.integrity("Expected an unchanged Wine builtin DLL, not a native replacement: \(path).")
            }
        }
    }
}
