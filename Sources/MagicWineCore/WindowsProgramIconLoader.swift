import CoreGraphics
import Foundation
import ImageIO

/// Reads local Windows icons without starting Wine or changing the bottle.
public actor WindowsProgramIconLoader {
    private final class CachedIcon {
        let modified: Date?
        let size: Int
        let image: CGImage?

        init(modified: Date?, size: Int, image: CGImage?) {
            self.modified = modified
            self.size = size
            self.image = image
        }
    }

    private let cache = NSCache<NSString, CachedIcon>()

    public init() {
        cache.countLimit = 256
    }

    public func image(for executableURL: URL, prefix: URL) -> CGImage? {
        guard executableURL.isFileURL, prefix.isFileURL, !Task.isCancelled else { return nil }
        let sources = ["lnk", "url"].contains(executableURL.pathExtension.lowercased())
            ? WindowsShortcut.candidates(for: executableURL, prefix: prefix)
            : [WindowsIconSource(url: executableURL, index: 0)]
        for source in sources {
            guard !Task.isCancelled else { return nil }
            if let image = image(from: source) { return image }
        }
        return nil
    }

    private func image(from source: WindowsIconSource) -> CGImage? {
        // URL caches resource values; a refresh must stat the current file, not its old metadata.
        var url = source.url
        url.removeAllCachedResourceValues()
        guard let attributes = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .fileSizeKey, .contentModificationDateKey
        ]), attributes.isRegularFile == true, let size = attributes.fileSize else { return nil }
        let key = "\(source.url.absoluteString)#\(source.index)" as NSString
        if let cached = cache.object(forKey: key), cached.size == size,
           cached.modified == attributes.contentModificationDate {
            return cached.image
        }

        let data: Data?
        if source.url.pathExtension.lowercased() == "ico" {
            data = size <= 16 * 1_048_576 ? try? Data(contentsOf: source.url, options: .mappedIfSafe) : nil
        } else {
            data = WindowsExecutableIcon.data(at: source.url, index: source.index)
        }
        let image = data.flatMap(Self.thumbnail)
        cache.setObject(CachedIcon(modified: attributes.contentModificationDate, size: size, image: image), forKey: key)
        return image
    }

    private static func thumbnail(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        // Decode at the row's Retina size rather than allocating an arbitrary full-size bitmap.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 76,
            kCGImageSourceShouldCacheImmediately: true
        ]
        var bestIndex = 0
        var bestSize = 0
        for index in 0..<CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            let size = max(width, height)
            // Prefer the smallest representation covering Retina; otherwise the largest available.
            if bestSize == 0 || (bestSize < 76 && size > bestSize) || (size >= 76 && size < bestSize) {
                bestIndex = index
                bestSize = size
            }
        }
        return CGImageSourceCreateThumbnailAtIndex(source, bestIndex, options as CFDictionary)
    }
}
