import ImageIO
import UIKit
import UniformTypeIdentifiers

/// A JPEG ready for Shum-Core (protocol section 04.9).
struct ShumPreparedPhoto: Equatable {
    let jpeg: Data
    let width: Int
    let height: Int
}

/// Turns a picked or taken photo into what a message carries: at most 1280
/// pixels on the long side, about 100 KB, and pixels only. The photo is drawn
/// anew, so no location, camera or time from the original file travels on.
enum ShumPhotoPreparation {
    static let longSide: CGFloat = 1280
    static let target = 110_000
    /// What every receiver accepts.
    static let limit = 131_072

    static func prepare(_ image: UIImage) -> ShumPreparedPhoto? {
        var side = longSide
        while side >= 320 {
            guard let pixels = draw(image, longSide: side) else { return nil }
            if let photo = fit(pixels) { return photo }
            side = (side * 0.8).rounded()
        }
        return nil
    }

    /// A picked file read already small: ImageIO decodes it straight at the
    /// size a message carries, never at the camera's full size, so a large
    /// photo is ready at once.
    static func prepare(data: Data) -> ShumPreparedPhoto? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var side = longSide
        while side >= 320 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(side),
            ]
            guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  // Drawn anew, opaque, so nothing of the original file travels on.
                  let pixels = draw(UIImage(cgImage: small), longSide: side) else { return nil }
            if let photo = fit(pixels) { return photo }
            side = (side * 0.8).rounded()
        }
        return nil
    }

    /// The best quality within the target size, if any.
    private static func fit(_ pixels: CGImage) -> ShumPreparedPhoto? {
        for quality in [0.8, 0.7, 0.6, 0.5, 0.42] {
            guard let jpeg = encode(pixels, quality: quality) else { return nil }
            if jpeg.count <= target {
                return ShumPreparedPhoto(jpeg: jpeg, width: pixels.width, height: pixels.height)
            }
        }
        return nil
    }

    /// Upright, at most `longSide` on the long side, one pixel per point.
    private static func draw(_ image: UIImage, longSide: CGFloat) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, longSide / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()),
                            height: max(1, (size.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }.cgImage
    }

    private static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
