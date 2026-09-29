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

    @Test func selfContainedProfileQRIsReadableAtPhoneDisplaySize() throws {
        let node = try ShumPermanentTests.Node("Alice", clock: ShumPermanentTests.Clock())
        let payload = try node.card.invitation().absoluteString
        let photo = try #require(makePhoto(size: CGSize(width: 756, height: 756),
            payload: payload, qrRect: CGRect(x: 60, y: 60, width: 636, height: 636), obscuresCenter: true))
        let image = try #require(photo.cgImage)
        #expect(ShumQRCodeDetector.payload(in: image) == payload)
    }

    /// The profile screen shows the complete signed card with correction M
    /// under the centered logo. Scanning it must produce the name and avatar
    /// seed directly, so adding the contact needs no network exchange.
    @Test func profileQRAddsContactWithoutNetwork() throws {
        let node = try ShumPermanentTests.Node("Alice", clock: ShumPermanentTests.Clock())
        let url = try node.card.invitation()
        #expect(url.host == "c4")
        // 212 pt code on a 2x screen, photographed or saved from the library.
        let photo = try #require(makePhoto(size: CGSize(width: 504, height: 504),
            payload: url.absoluteString, qrRect: CGRect(x: 40, y: 40, width: 424, height: 424),
            obscuresCenter: true, correctionLevel: "M"))
        let image = try #require(photo.cgImage)
        let scanned = try #require(ShumQRCodeDetector.payload(in: image))
        #expect(scanned == url.absoluteString)
        guard case .card(let card) = try ShumInvitationPayload.parse(try #require(URL(string: scanned))) else {
            Issue.record("A profile QR must not require a network lookup")
            return
        }
        #expect(card.name == "Alice")
        #expect(card.avatarSeed != nil && card.avatarSeed == node.card.avatarSeed)
        #expect(card.id == node.card.id)
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
        obscuresCenter: Bool,
        correctionLevel: String = "H"
    ) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = correctionLevel
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
