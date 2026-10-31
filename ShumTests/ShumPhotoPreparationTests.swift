import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Shum

@Suite("Photo preparation")
struct ShumPhotoPreparationTests {
    /// A camera-sized JPEG with location, time and camera metadata, as the
    /// photo library hands it over.
    private func cameraPhoto(orientation: Int = 1) throws -> UIImage {
        let size = CGSize(width: 4032, height: 3024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let pixels = try #require(UIGraphicsImageRenderer(size: size, format: format).image { context in
            for i in 0..<40 {
                UIColor(hue: CGFloat(i) / 40, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(i) * 100.8, y: 0, width: 100.8, height: size.height))
            }
        }.cgImage)
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.75, kCGImagePropertyGPSLongitude: 37.61],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:31 09:41:00"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "iPhone 17"],
        ]
        CGImageDestinationAddImage(destination, pixels, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return try #require(UIImage(data: data as Data))
    }

    @Test("A camera photo leaves small, upright and with pixels only")
    func cameraPhotoIsSmallAndBare() throws {
        let prepared = try #require(ShumPhotoPreparation.prepare(try cameraPhoto()))
        #expect(prepared.width == 1280 && prepared.height == 960)
        #expect(prepared.jpeg.count <= ShumPhotoPreparation.limit)
        #expect(prepared.jpeg.starts(with: [0xff, 0xd8, 0xff]))
        let source = try #require(CGImageSourceCreateWithData(prepared.jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] == nil)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFModel] == nil)
    }

    @Test("A photo taken sideways is turned upright")
    func sidewaysPhotoIsUpright() throws {
        // EXIF orientation 6: the pixels are stored turned; shown portrait.
        let prepared = try #require(ShumPhotoPreparation.prepare(try cameraPhoto(orientation: 6)))
        #expect(prepared.width == 960 && prepared.height == 1280)
    }
}
