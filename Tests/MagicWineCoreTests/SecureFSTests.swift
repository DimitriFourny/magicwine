import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MagicWineCore

struct SecureFSTests {
    private let fs = SecureFS(prefix: "Test: ")

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func put32(_ value: UInt32, at offset: Int, into data: inout Data, bigEndian: Bool = false) {
        for index in 0..<4 {
            data[offset + index] = UInt8(truncatingIfNeeded: value >> (8 * (bigEndian ? 3 - index : index)))
        }
    }

    // MARK: Bounded hashing

    @Test func hashingEnforcesTheExactSizeLimitAndRejectsLinksAndEmptyFiles() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        let bytes = Data(repeating: 0x5a, count: 4096)
        try bytes.write(to: file)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(try fs.sha256(file, maximum: 4096) == expected)
        #expect(try fs.read(file, maximum: 4096) == bytes)
        #expect(throws: MagicWineError.self) { try fs.sha256(file, maximum: 4095) }
        #expect(throws: MagicWineError.self) { try fs.read(file, maximum: 4095) }

        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: MagicWineError.self) { try fs.sha256(link, maximum: 4096) }
        #expect(throws: MagicWineError.self) { try fs.requireFile(link, maximum: 4096) }

        let hardLink = root.appendingPathComponent("hardlink")
        try FileManager.default.linkItem(at: file, to: hardLink)
        #expect(throws: MagicWineError.self) { try fs.sha256(hardLink, maximum: 4096) }
        #expect(throws: MagicWineError.self) { try fs.requireFile(file, maximum: 4096) }
        #expect(try fs.sha256(hardLink, maximum: 4096, allowsHardLinks: true) == expected)
        try fs.requireFile(file, maximum: 4096, allowsHardLinks: true)

        let empty = root.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(throws: MagicWineError.self) { try fs.sha256(empty, maximum: 4096) }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test func validationCacheSkipsOnlyUnchangedStampsAndRejectsChangesDuringVerification() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("payload")
        try Data("first".utf8).write(to: file)
        let cache = SecureFS.ValidationCache()
        var runs = 0
        func verify() throws {
            try cache.verify(root, names: ["", "payload"], fs: fs, rehash: false, changed: .setup("changed")) { runs += 1 }
        }
        try verify()
        try verify()
        #expect(runs == 1)
        try cache.verify(root, names: ["", "payload"], fs: fs, rehash: true, changed: .setup("changed")) { runs += 1 }
        #expect(runs == 2)
        // Same-size content changes still replace mtime/ctime evidence.
        try Data("other".utf8).write(to: file)
        try verify()
        #expect(runs == 3)
        #expect(throws: MagicWineError.self) {
            try cache.verify(root, names: ["payload"], fs: fs, rehash: true, changed: .setup("changed")) {
                try Data("third".utf8).write(to: file)
            }
        }
        // A failed verification is never remembered as evidence.
        try verify()
        #expect(runs == 4)
    }

    @Test func exclusivePublicationNeverReplacesAnOccupiedDestination() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stage = root.appendingPathComponent("stage", isDirectory: true)
        let destination = root.appendingPathComponent("published", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        try Data("staged".utf8).write(to: stage.appendingPathComponent("file"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        #expect(try !fs.publish(stage, to: destination))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(FileManager.default.fileExists(atPath: stage.appendingPathComponent("file").path))
        try FileManager.default.removeItem(at: destination)
        #expect(try fs.publish(stage, to: destination))
        #expect(try Data(contentsOf: destination.appendingPathComponent("file")) == Data("staged".utf8))
        #expect(!FileManager.default.fileExists(atPath: stage.path))
    }

    // MARK: Mach-O

    private func thinImage(cpu: UInt32 = MachOInspector.x86_64, minimum: UInt32 = 15 << 16) -> Data {
        var bytes = Data(repeating: 0, count: 56)
        put32(0xfeedfacf, at: 0, into: &bytes)
        put32(cpu, at: 4, into: &bytes)
        put32(6, at: 12, into: &bytes)
        put32(1, at: 16, into: &bytes)
        put32(24, at: 20, into: &bytes)
        put32(0x32, at: 32, into: &bytes)
        put32(24, at: 36, into: &bytes)
        put32(1, at: 40, into: &bytes)
        put32(minimum, at: 44, into: &bytes)
        return bytes
    }

    private func universalImage(_ slices: [(cpu: UInt32, minimum: UInt32)]) -> Data {
        var bytes = Data(repeating: 0, count: 4096 * (slices.count + 1))
        put32(0xcafebabe, at: 0, into: &bytes, bigEndian: true)
        put32(UInt32(slices.count), at: 4, into: &bytes, bigEndian: true)
        for (index, slice) in slices.enumerated() {
            let offset = 4096 * (index + 1)
            put32(slice.cpu, at: 8 + index * 20, into: &bytes, bigEndian: true)
            put32(UInt32(offset), at: 16 + index * 20, into: &bytes, bigEndian: true)
            put32(56, at: 20 + index * 20, into: &bytes, bigEndian: true)
            bytes.replaceSubrange(offset..<(offset + 56), with: thinImage(cpu: slice.cpu, minimum: slice.minimum))
        }
        return bytes
    }

    @Test func universalInspectionReadsOnlyTheSingleX86Slice() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("library.dylib")
        try universalImage([(MachOInspector.arm64, 26 << 16), (MachOInspector.x86_64, 15 << 16 | 1 << 8)]).write(to: binary)
        let image = try MachOInspector.inspect(binary, fs: fs, maximum: 1_048_576, universal: true, exports: false)
        #expect(image.minimumOS == 15 << 16 | 1 << 8)
        #expect(image.fileType == 6)
        #expect(throws: MagicWineError.self) {
            try MachOInspector.inspect(binary, fs: fs, maximum: 1_048_576, universal: false, exports: false)
        }
        try universalImage([(MachOInspector.x86_64, 15 << 16), (MachOInspector.x86_64, 15 << 16)]).write(to: binary)
        #expect(throws: MagicWineError.self) {
            try MachOInspector.inspect(binary, fs: fs, maximum: 1_048_576, universal: true, exports: false)
        }
        try universalImage([(MachOInspector.arm64, 15 << 16)]).write(to: binary)
        #expect(throws: MagicWineError.self) {
            try MachOInspector.inspect(binary, fs: fs, maximum: 1_048_576, universal: true, exports: false)
        }
        var outside = universalImage([(MachOInspector.x86_64, 15 << 16)])
        put32(UInt32(outside.count), at: 16, into: &outside, bigEndian: true)
        try outside.write(to: binary)
        #expect(throws: MagicWineError.self) {
            try MachOInspector.inspect(binary, fs: fs, maximum: 1_048_576, universal: true, exports: false)
        }
    }

    @Test func cpuTypeDetectionCoversThinAndUniversalHeaders() {
        var littleEndianThin = Data(repeating: 0, count: 8)
        put32(0xfeedfacf, at: 0, into: &littleEndianThin)
        put32(MachOInspector.x86_64, at: 4, into: &littleEndianThin)
        #expect(MachOInspector.cpuTypes(in: littleEndianThin) == [MachOInspector.x86_64])
        #expect(MachOInspector.cpuTypes(in: thinImage(cpu: MachOInspector.arm64)) == [MachOInspector.arm64])

        let universal = universalImage([(MachOInspector.x86_64, 0), (MachOInspector.arm64, 0)])
        #expect(MachOInspector.cpuTypes(in: universal.prefix(4096)) == [MachOInspector.x86_64, MachOInspector.arm64])
        // A table extending beyond the inspected prefix is not trusted.
        #expect(MachOInspector.cpuTypes(in: universal.prefix(40)) == nil)

        var fat64 = Data(repeating: 0, count: 8 + 32)
        put32(0xcafebabf, at: 0, into: &fat64, bigEndian: true)
        put32(1, at: 4, into: &fat64, bigEndian: true)
        put32(MachOInspector.x86_64, at: 8, into: &fat64, bigEndian: true)
        #expect(MachOInspector.cpuTypes(in: fat64) == [MachOInspector.x86_64])
        var swappedFat = Data(repeating: 0, count: 8 + 20)
        put32(0xcafebabe, at: 0, into: &swappedFat)
        put32(1, at: 4, into: &swappedFat)
        put32(MachOInspector.arm64, at: 8, into: &swappedFat)
        #expect(MachOInspector.cpuTypes(in: swappedFat) == [MachOInspector.arm64])

        #expect(MachOInspector.cpuTypes(in: Data([0xcf, 0xfa, 0xed, 0xfe])) == nil)
        #expect(MachOInspector.cpuTypes(in: Data("#!/bin/sh\nexec wine\n".utf8)) == nil)
    }

    // MARK: PE

    private func peImage(machine: UInt16 = PEInspector.amd64, marker: String? = nil, magic: UInt16 = 0x020b) -> Data {
        var bytes = Data(repeating: 0, count: 256)
        bytes[0] = 0x4d; bytes[1] = 0x5a; bytes[60] = 128
        if let marker { bytes.replaceSubrange(64..<(64 + marker.utf8.count), with: Data(marker.utf8)) }
        bytes[128] = 0x50; bytes[129] = 0x45
        bytes[132] = UInt8(truncatingIfNeeded: machine); bytes[133] = UInt8(machine >> 8)
        bytes[148] = 0x60; bytes[151] = 0x20
        bytes[152] = UInt8(truncatingIfNeeded: magic); bytes[153] = UInt8(magic >> 8)
        return bytes
    }

    @Test func peMarkersMachineAndOptionalHeaderRequirementsStayExplicit() throws {
        let builtin = peImage(marker: "Wine builtin DLL\0")
        let placeholder = peImage(marker: "Wine placeholder DLL\0")
        let native = peImage()
        try PEInspector.validateDLL(builtin, path: "builtin", machine: PEInspector.amd64, markers: [.builtin], fs: fs)
        try PEInspector.validateDLL(placeholder, path: "placeholder", machine: PEInspector.amd64,
                                    markers: [.builtin, .placeholder], fs: fs)
        try PEInspector.validateDLL(native, path: "native", machine: PEInspector.amd64, fs: fs)
        #expect(throws: MagicWineError.self) {
            try PEInspector.validateDLL(placeholder, path: "placeholder", machine: PEInspector.amd64, markers: [.builtin], fs: fs)
        }
        #expect(throws: MagicWineError.self) {
            try PEInspector.validateDLL(native, path: "native", machine: PEInspector.amd64, markers: [.builtin, .placeholder], fs: fs)
        }
        #expect(throws: MagicWineError.self) {
            try PEInspector.validateDLL(native, path: "native", machine: PEInspector.i386, fs: fs)
        }
        let noOptionalHeader = peImage(magic: 0)
        try PEInspector.validateDLL(noOptionalHeader, path: "minimal", machine: PEInspector.amd64,
                                    requiresOptionalHeader: false, fs: fs)
        #expect(throws: MagicWineError.self) {
            try PEInspector.validateDLL(noOptionalHeader, path: "minimal", machine: PEInspector.amd64, fs: fs)
        }
        // PE32 magic is only native for i386.
        #expect(throws: MagicWineError.self) {
            try PEInspector.validateDLL(peImage(magic: 0x010b), path: "pe32", machine: PEInspector.amd64, fs: fs)
        }
        try PEInspector.validateDLL(peImage(machine: PEInspector.i386, magic: 0x010b), path: "pe32",
                                    machine: PEInspector.i386, fs: fs)
    }

    @Test func peFileValidationAppliesTheCallerSizeLimitWithoutFollowingLinks() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let dll = root.appendingPathComponent("d3d11.dll")
        try peImage().write(to: dll)
        try PEInspector.validateDLL(dll, machine: PEInspector.amd64, fs: fs, maximum: 256)
        #expect(throws: MagicWineError.self) { try PEInspector.validateDLL(dll, machine: PEInspector.amd64, fs: fs, maximum: 255) }
        let link = root.appendingPathComponent("linked.dll")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dll)
        #expect(throws: MagicWineError.self) { try PEInspector.validateDLL(link, machine: PEInspector.amd64, fs: fs, maximum: 256) }
    }
}
