#if os(iOS)
import ImageIO
import UIKit

@MainActor
enum ShumAvatarCodec {
    static func prepare(_ data: Data) throws -> Data {
        guard data.count <= 30 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 720,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let image = UIImage(cgImage: cg)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let square = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 360), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 360, height: 360))
            let scale = 360 / min(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (360 - size.width) / 2, y: (360 - size.height) / 2, width: size.width, height: size.height))
        }
        for quality in [0.88, 0.75, 0.6, 0.45, 0.3, 0.18] {
            if let jpeg = square.jpegData(compressionQuality: quality), jpeg.count <= ShumProfile.maxAvatarBytes { return jpeg }
        }
        throw CocoaError(.fileWriteOutOfSpace)
    }
    #if DEBUG
    static func diagnosticPhoto(seed: Int) -> Data? {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 360), format: format).image { ctx in
            for y in stride(from: 0, to: 360, by: 8) {
                for x in stride(from: 0, to: 360, by: 8) {
                    UIColor(red: CGFloat((x * 7 + y * 3 + seed) % 255) / 255,
                            green: CGFloat((x * 3 + y * 11 + seed) % 255) / 255,
                            blue: CGFloat((x * 13 + y * 7 + seed) % 255) / 255, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        guard let png = image.pngData() else { return nil }
        return try? prepare(png)
    }
    #endif

}
#endif
