import CoreGraphics
import Foundation
import Testing
@testable import MagicWineCore

struct WindowsProgramIconLoaderTests {
    @Test func replacingAnIconAtTheSamePathRefreshesItsPixels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("game.ico")
        let loader = WindowsProgramIconLoader()
        try icon(red: 255, green: 0).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: url.path)
        let first = try #require(await loader.image(for: url, prefix: root))
        #expect(pixel(first) == [255, 0, 0, 255])

        try icon(red: 0, green: 255).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: url.path)
        let replaced = try #require(await loader.image(for: url, prefix: root))
        #expect(pixel(replaced) == [0, 255, 0, 255])
    }

    @Test func aMissingOrDamagedIconCanBeRepairedWithoutRestarting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("game.ico")
        let loader = WindowsProgramIconLoader()
        #expect(await loader.image(for: url, prefix: root) == nil)
        try Data([0, 0, 1, 0, 1, 0]).write(to: url)
        #expect(await loader.image(for: url, prefix: root) == nil)
        try icon(red: 255, green: 0).write(to: url)
        let repaired = try #require(await loader.image(for: url, prefix: root))
        #expect(pixel(repaired) == [255, 0, 0, 255])
    }

    @Test func damagedShortcutIconFallsBackToTheTargetIcon() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("damaged icon".utf8).write(to: root.appendingPathComponent("custom.ico"))
        try icon(red: 0, green: 255).write(to: root.appendingPathComponent("target.ico"))
        var link = Data(count: 76)
        link[0] = 76
        link.replaceSubrange(4..<20, with: [1, 20, 2, 0, 0, 0, 0, 0, 192, 0, 0, 0, 0, 0, 0, 70])
        link[20] = 0xc8 // Unicode RelativePath and IconLocation.
        for path in ["target.ico", "custom.ico"] {
            let units = Array(path.utf16)
            link.append(contentsOf: [UInt8(units.count), 0])
            for unit in units {
                link.append(contentsOf: [UInt8(truncatingIfNeeded: unit), UInt8(unit >> 8)])
            }
        }
        link.append(contentsOf: [0, 0, 0, 0])
        let url = root.appendingPathComponent("game.lnk")
        try link.write(to: url)
        let loader = WindowsProgramIconLoader()
        let image = try #require(await loader.image(for: url, prefix: root))
        #expect(pixel(image) == [0, 255, 0, 255])
    }

    private func icon(red: UInt8, green: UInt8) -> Data {
        // ImageIO supports Windows icon sizes starting at 16x16.
        var bytes: [UInt8] = [0, 0, 1, 0, 1, 0, 16, 16, 0, 0, 1, 0, 32, 0, 104, 4, 0, 0, 22, 0, 0, 0]
        bytes += [40, 0, 0, 0, 16, 0, 0, 0, 32, 0, 0, 0, 1, 0, 32, 0]
        bytes += Array(repeating: 0, count: 24)
        for _ in 0..<256 { bytes += [0, green, red, 255] }
        bytes += Array(repeating: 0, count: 64)
        return Data(bytes)
    }

    private func pixel(_ image: CGImage) -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}
