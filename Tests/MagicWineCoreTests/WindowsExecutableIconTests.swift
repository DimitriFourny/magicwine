import AppKit
import Foundation
import Testing
@testable import MagicWineCore

struct WindowsExecutableIconTests {
    @Test(arguments: [false, true])
    func reconstructsDecodableIconsAndPreservesEveryFrame(pe32Plus: Bool) throws {
        let fixture = try Fixture(pe32Plus: pe32Plus)
        try withFile(fixture.file, extension: "exe") { url in
            let ico = try #require(WindowsExecutableIcon.data(at: url))
            #expect(value(ico, 0, bytes: 2) == 0)
            #expect(value(ico, 2, bytes: 2) == 1)
            #expect(value(ico, 4, bytes: 2) == 2)
            #expect(ico[6] == 16)
            #expect(ico[22] == 32)
            #expect(value(ico, 12, bytes: 2) == 32)
            #expect(try frames(ico) == Array(fixture.images.prefix(2)))
            #expect(NSImage(data: ico) != nil)
            #expect(WindowsExecutableIcon.data(at: url, index: -42) == ico)
        }
    }

    @Test func selectsOrdinalOrResourceIDAndPreservesPNGTransparency() throws {
        let fixture = try Fixture(pe32Plus: true)
        try withFile(fixture.file, extension: "dll") { url in
            let ico = try #require(WindowsExecutableIcon.data(at: url, index: 1))
            #expect(WindowsExecutableIcon.data(at: url, index: -77) == ico)
            #expect(value(ico, 4, bytes: 2) == 1)
            #expect(ico[6] == 0) // ICO represents 256 pixels with zero.
            #expect(ico[7] == 0)
            #expect(try frames(ico) == [fixture.images[2]])
            let image = try #require(NSImage(data: ico))
            #expect(image.size.width == 256)
            #expect(image.size.height == 256)
            let bitmap = try #require(NSBitmapImageRep(data: fixture.images[2]))
            #expect(bitmap.hasAlpha)
            #expect(try #require(bitmap.colorAt(x: 0, y: 0)).alphaComponent == 0)
            for index in [2, 42, -1, -999, Int.min, Int.max] {
                #expect(WindowsExecutableIcon.data(at: url, index: index) == nil)
            }
        }
    }

    @Test func rejectsCorruptResourceOffsetsCountsAndPayloads() throws {
        let fixture = try Fixture(pe32Plus: false)
        let base = Fixture.resourceFileOffset
        let mutations: [(Int, UInt32, Int)] = [
            (60, UInt32.max, 4),                           // DOS points outside the file.
            (Fixture.peOffset + 6, UInt32(UInt16.max), 2), // Excessive section count.
            (Fixture.peOffset + 20, 1, 2),                 // Missing optional header.
            (fixture.directoryOffset - 4, 2, 4),          // Resource data directory absent.
            (fixture.directoryOffset + 20, UInt32.max, 4),
            (fixture.sectionOffset + 16, UInt32.max, 4),
            (fixture.sectionOffset + 20, UInt32.max, 4),
            (base + 14, UInt32(UInt16.max), 2),            // Directory entries exceed its extent.
            (base + 20, UInt32.max, 4),                    // Invalid RT_ICON directory pointer.
            (base + 24, 15, 4),                           // RT_GROUP_ICON missing.
            (base + 28, 0x8000_0000, 4),                   // Cycle back to root.
            (fixture.groupDirectory + 20, 0x8000_0000, 4), // Language points to another directory.
            (fixture.groupDescriptor, UInt32.max, 4),
            (fixture.groupDescriptor + 4, UInt32.max, 4),
            (fixture.groupPayload + 4, UInt32(UInt16.max), 2),
            (fixture.groupPayload + 6 + 8, UInt32.max, 4), // Group size differs from actual image.
            (fixture.groupPayload + 6 + 12, 999, 2),       // Missing RT_ICON resource.
            (fixture.iconDescriptor, UInt32.max, 4),
            (fixture.iconDescriptor + 4, UInt32.max, 4),
            (fixture.iconDescriptor, UInt32(Fixture.resourceRVA + fixture.resourceSize), 4)
        ]
        for (offset, newValue, bytes) in mutations {
            var corrupt = fixture.file
            put(newValue, into: &corrupt, at: offset, bytes: bytes)
            try withFile(corrupt) { url in
                #expect(WindowsExecutableIcon.data(at: url) == nil)
            }
        }
    }

    @Test func rejectsTruncatedOrNonExecutableFiles() throws {
        let fixture = try Fixture(pe32Plus: true)
        for end in [0, 1, 63, 127, 151, fixture.sectionOffset + 39,
                    Fixture.resourceFileOffset + 15, fixture.file.count - 1] {
            try withFile(Data(fixture.file.prefix(end))) { url in
                #expect(WindowsExecutableIcon.data(at: url) == nil)
            }
        }
        try withFile(Data("not a Windows executable".utf8)) { url in
            #expect(WindowsExecutableIcon.data(at: url) == nil)
        }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        #expect(WindowsExecutableIcon.data(at: missing) == nil)
    }

    @Test func ignoresLargeExecutableOverlay() throws {
        let fixture = try Fixture(pe32Plus: false)
        try withFile(fixture.file) { url in
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: 512 * 1024 * 1024)
            try handle.write(contentsOf: Data([0]))
            let ico = try #require(WindowsExecutableIcon.data(at: url))
            #expect(try frames(ico) == Array(fixture.images.prefix(2)))
        }
    }

    private func withFile(_ data: Data, extension suffix: String = "exe", body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.\(suffix)")
        try data.write(to: url)
        try body(url)
    }

    private func frames(_ ico: Data) throws -> [Data] {
        let count = Int(value(ico, 4, bytes: 2))
        var images: [Data] = []
        for index in 0..<count {
            let size = Int(value(ico, 6 + index * 16 + 8))
            let offset = Int(value(ico, 6 + index * 16 + 12))
            try #require(offset >= 6 + count * 16 && offset <= ico.count)
            try #require(size <= ico.count - offset)
            images.append(ico.subdata(in: offset..<(offset + size)))
        }
        return images
    }

    private struct Fixture {
        static let peOffset = 128
        static let resourceFileOffset = 544
        static let resourceRVA = 0x1020
        let file: Data
        let images: [Data]
        let directoryOffset: Int
        let sectionOffset: Int
        let resourceSize: Int
        let groupDirectory: Int
        let groupDescriptor: Int
        let groupPayload: Int
        let iconDescriptor: Int

        init(pe32Plus: Bool) throws {
            let bitmap = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            let pixels = try #require(bitmap.bitmapData)
            pixels.initialize(repeating: 0, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            images = [Self.dib(size: 16, red: 255), Self.dib(size: 32, red: 96), png]
            var resources = ResourceBuilder()
            let root = resources.directory(count: 2)
            let icons = resources.directory(count: 3)
            let groups = resources.directory(count: 2)
            resources.entry(in: root, index: 0, id: 3, target: icons)
            resources.entry(in: root, index: 1, id: 14, target: groups)
            var firstIconDescriptor = 0
            for index in 0..<3 {
                let leaf = resources.leaf(images[index])
                resources.entry(in: icons, index: index, id: UInt32(index + 1), target: leaf.directory)
                if index == 0 { firstIconDescriptor = leaf.descriptor }
            }
            let firstGroup = resources.leaf(Self.group(ids: [1, 2], sizes: [16, 32], images: images))
            let secondGroup = resources.leaf(Self.group(ids: [3], sizes: [256], images: images))
            resources.entry(in: groups, index: 0, id: 42, target: firstGroup.directory)
            resources.entry(in: groups, index: 1, id: 77, target: secondGroup.directory)
            resourceSize = resources.data.count
            groupDirectory = Self.resourceFileOffset + firstGroup.directory
            groupDescriptor = Self.resourceFileOffset + firstGroup.descriptor
            groupPayload = Self.resourceFileOffset + firstGroup.payload
            iconDescriptor = Self.resourceFileOffset + firstIconDescriptor

            let optionalSize = pe32Plus ? 240 : 224
            let optionalOffset = Self.peOffset + 24
            directoryOffset = optionalOffset + (pe32Plus ? 112 : 96)
            sectionOffset = optionalOffset + optionalSize
            var executable = Data(count: Self.resourceFileOffset)
            put(0x5a4d, into: &executable, at: 0, bytes: 2)
            put(UInt32(Self.peOffset), into: &executable, at: 60)
            put(0x4550, into: &executable, at: Self.peOffset)
            put(pe32Plus ? 0x8664 : 0x14c, into: &executable, at: Self.peOffset + 4, bytes: 2)
            put(1, into: &executable, at: Self.peOffset + 6, bytes: 2)
            put(UInt32(optionalSize), into: &executable, at: Self.peOffset + 20, bytes: 2)
            put(pe32Plus ? 0x20b : 0x10b, into: &executable, at: optionalOffset, bytes: 2)
            put(16, into: &executable, at: directoryOffset - 4)
            put(UInt32(Self.resourceRVA), into: &executable, at: directoryOffset + 16)
            put(UInt32(resourceSize), into: &executable, at: directoryOffset + 20)
            put(UInt32(resourceSize + 32), into: &executable, at: sectionOffset + 8)
            put(0x1000, into: &executable, at: sectionOffset + 12)
            put(UInt32(resourceSize + 32), into: &executable, at: sectionOffset + 16)
            put(512, into: &executable, at: sectionOffset + 20)
            executable.append(resources.data)
            file = executable
        }

        private static func dib(size: Int, red: UInt8) -> Data {
            let pixelCount = size * size * 4
            let maskSize = ((size + 31) / 32) * 4 * size
            var data = Data(count: 40 + pixelCount + maskSize)
            put(40, into: &data, at: 0)
            put(UInt32(size), into: &data, at: 4)
            put(UInt32(size * 2), into: &data, at: 8)
            put(1, into: &data, at: 12, bytes: 2)
            put(32, into: &data, at: 14, bytes: 2)
            put(UInt32(pixelCount), into: &data, at: 20)
            for pixel in stride(from: 40, to: 40 + pixelCount, by: 4) {
                data[pixel + 2] = red
                data[pixel + 3] = 128
            }
            return data
        }

        private static func group(ids: [Int], sizes: [Int], images: [Data]) -> Data {
            var data = Data(count: 6 + ids.count * 14)
            put(1, into: &data, at: 2, bytes: 2)
            put(UInt32(ids.count), into: &data, at: 4, bytes: 2)
            for index in ids.indices {
                let offset = 6 + index * 14
                data[offset] = UInt8(truncatingIfNeeded: sizes[index])
                data[offset + 1] = data[offset]
                put(1, into: &data, at: offset + 4, bytes: 2)
                put(32, into: &data, at: offset + 6, bytes: 2)
                put(UInt32(images[ids[index] - 1].count), into: &data, at: offset + 8)
                put(UInt32(ids[index]), into: &data, at: offset + 12, bytes: 2)
            }
            return data
        }
    }

    private struct ResourceBuilder {
        var data = Data()

        mutating func directory(count: Int) -> Int {
            let offset = data.count
            data.append(Data(count: 16 + count * 8))
            put(UInt32(count), into: &data, at: offset + 14, bytes: 2)
            return offset
        }

        mutating func entry(in directory: Int, index: Int, id: UInt32, target: Int, isDirectory: Bool = true) {
            put(id, into: &data, at: directory + 16 + index * 8)
            put(UInt32(target) | (isDirectory ? 0x8000_0000 : 0), into: &data, at: directory + 20 + index * 8)
        }

        mutating func leaf(_ payload: Data) -> (directory: Int, descriptor: Int, payload: Int) {
            while data.count % 4 != 0 { data.append(0) }
            let languages = directory(count: 1)
            let descriptor = data.count
            data.append(Data(count: 16))
            let payloadOffset = data.count
            data.append(payload)
            entry(in: languages, index: 0, id: 0, target: descriptor, isDirectory: false)
            put(UInt32(Fixture.resourceRVA + payloadOffset), into: &data, at: descriptor)
            put(UInt32(payload.count), into: &data, at: descriptor + 4)
            return (languages, descriptor, payloadOffset)
        }
    }
}

private func put(_ value: UInt32, into data: inout Data, at offset: Int, bytes: Int = 4) {
    for byte in 0..<bytes { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
}

private func value(_ data: Data, _ offset: Int, bytes: Int = 4) -> UInt32 {
    var result: UInt32 = 0
    for byte in 0..<bytes { result |= UInt32(data[offset + byte]) << (byte * 8) }
    return result
}
