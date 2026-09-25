import CoreImage.CIFilterBuiltins
import Testing
import UIKit
@testable import Shum

@Suite("Gallery QR scanner")
@MainActor
struct ShumGalleryScannerTests {
    @Test func scannerReadsTheAreaDisplayedInsideItsFrame() throws {
        let payload = "shum://c2/AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
        let viewport = CGSize(width: 390, height: 844)
        let scanRect = CGRect(x: 63, y: 290, width: 264, height: 264)
        let photo = try #require(makePhoto(
            size: viewport,
            payload: payload,
            qrRect: scanRect.insetBy(dx: 22, dy: 22),
            obscuresCenter: true
        ))
        let framed = try #require(ShumScannerPhotoRenderer.render(
            photo,
            viewportSize: viewport,
            scanRect: scanRect,
            zoom: 1,
            offset: .zero
        ))
        let cgImage = try #require(framed.cgImage)
        #expect(ShumQRCodeDetector.payload(in: cgImage) == payload)
    }

    @Test func scannerReadsAnOrientedLibraryPhotoAtFullResolution() throws {
        let payload = "shum://c2/AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
        let source = try #require(makePhoto(
            size: CGSize(width: 1600, height: 1200),
            payload: payload,
            qrRect: CGRect(x: 520, y: 320, width: 560, height: 560),
            obscuresCenter: true
        ))
        let sourceCGImage = try #require(source.cgImage)
        let libraryPhoto = UIImage(cgImage: sourceCGImage, scale: 1, orientation: .right)
        let normalized = try #require(ShumScannerPhotoRenderer.normalizedCGImage(libraryPhoto))

        #expect(ShumQRCodeDetector.payload(in: normalized) == payload)
    }

    @Test func invalidGeometryDoesNotProduceAnImage() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { _ in }
        #expect(ShumScannerPhotoRenderer.render(
            image,
            viewportSize: .zero,
            scanRect: .zero,
            zoom: 1,
            offset: .zero
        ) == nil)
    }

    private func makePhoto(
        size: CGSize,
        payload: String,
        qrRect: CGRect,
        obscuresCenter: Bool
    ) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let qr = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIImage(cgImage: qr).draw(in: qrRect)
            if obscuresCenter {
                // The QR shown by Shum has a white 42pt logo plate over a
                // 212pt code, so the test keeps the same occupied area.
                let coverSide = qrRect.width * 0.20
                UIColor.white.setFill()
                context.fill(CGRect(
                    x: qrRect.midX - coverSide / 2,
                    y: qrRect.midY - coverSide / 2,
                    width: coverSide,
                    height: coverSide
                ))
            }
        }
    }
}
