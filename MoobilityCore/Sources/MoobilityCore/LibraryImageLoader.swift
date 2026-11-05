import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Loads photos with ImageIO instead of `CIImage(contentsOf:)`, which ignores EXIF orientation and
/// would leave a huge photo to be decoded lazily on the video path. Both entry points always
/// generate their own downsampled copy, apply the orientation, and decode it immediately.
public enum LibraryImageLoader {
    /// A background for the compositor: at most 2560 px on the long edge, upright, backed by a decoded bitmap.
    /// Nil if ImageIO can't decode the file (not an image, a truncated file, an SVG).
    public static func background(at url: URL) -> CIImage? {
        decode(url, maxPixelSize: 2560).map { CIImage(cgImage: $0) }
    }

    /// A grid tile: at most 640 px on the long edge, upright and decoded. Nil on any failure.
    public static func thumbnail(at url: URL) -> CGImage? {
        decode(url, maxPixelSize: 640)
    }

    private static func decode(_ url: URL, maxPixelSize limit: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0 else { return nil }

        // Never upscale: a thumbnail request bigger than the image would enlarge it. Orientation can
        // swap width and height but not the long edge, so the stored dimensions are enough.
        var maxPixelSize = limit
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? Int,
           let height = properties[kCGImagePropertyPixelHeight] as? Int,
           max(width, height) > 0 {
            maxPixelSize = min(limit, max(width, height))
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
