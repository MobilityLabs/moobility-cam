import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// Puts the masked person from a camera frame over a background, at the fixed output size.
public final class Compositor: @unchecked Sendable {
    public static let outputSize = CGSize(width: 1280, height: 720)
    static let maskEdgeSigma: Double = 2

    private let context: CIContext
    private let lock = NSLock()
    private var background: CIImage?
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(context: CIContext = CIContext(options: [.useSoftwareRenderer: false])) {
        self.context = context
    }

    /// Scales `image` to cover `size` without distortion, centre-crops, and moves the result to the origin.
    public static func aspectFill(_ image: CIImage, to size: CGSize) -> CIImage {
        let e = image.extent
        let scale = max(size.width / e.width, size.height / e.height)
        let tx = (size.width - e.width * scale) / 2
        let ty = (size.height - e.height * scale) / 2
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        return image.transformed(by: t).cropped(to: CGRect(origin: .zero, size: size))
    }

    public func setBackground(_ image: CIImage) {
        let filled = Self.aspectFill(image, to: Self.outputSize)
        lock.lock(); background = filled; lock.unlock()
    }

    /// The aspect-filled background, or opaque black at the output size when none is set.
    public func backgroundFrame() -> CIImage {
        lock.lock(); let bg = background; lock.unlock()
        return bg ?? CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(origin: .zero, size: Self.outputSize))
    }

    /// The camera alone, aspect-filled to the output size.
    public func plain(camera: CIImage) -> CIImage {
        Self.aspectFill(camera, to: Self.outputSize)
    }

    /// `mask` is a full-frame person mask at any resolution (white = person). `nil` returns the
    /// background alone (black when none is set): the raw camera is never returned. With a mask
    /// but no background, the person is blended over opaque black.
    public func composite(camera: CIImage, mask: CIImage?) -> CIImage {
        guard let mask else { return backgroundFrame() }
        let size = Self.outputSize
        let cam = Self.aspectFill(camera, to: size)
        let bg = backgroundFrame()

        let ce = camera.extent, me = mask.extent
        let stretched = mask
            .transformed(by: CGAffineTransform(translationX: -me.minX, y: -me.minY)
                .concatenating(CGAffineTransform(scaleX: ce.width / me.width, y: ce.height / me.height))
                .concatenating(CGAffineTransform(translationX: ce.minX, y: ce.minY)))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Self.maskEdgeSigma)
            .cropped(to: ce)
        let softMask = Self.aspectFill(stretched, to: size)

        return cam.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: bg,
            kCIInputMaskImageKey: softMask,
        ]).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// `from` dissolving into `to`: `from` at mix 0, `to` at mix 1.
    public func blend(from: CIImage, to: CIImage, mix: Double) -> CIImage {
        from.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: to,
            kCIInputTimeKey: mix,
        ]).cropped(to: CGRect(origin: .zero, size: Self.outputSize))
    }

    public func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: Self.outputSize), colorSpace: sRGB)
    }
}
