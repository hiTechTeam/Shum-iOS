import SwiftUI
import UIKit

struct ShumOnboardingPixelIllustration: View {
    enum Kind { case nearby, mesh, courier, network, identity, security, passcode, faceID, success, failure }

    let kind: Kind
    private let unit: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let drawingSize = CGSize(width: 24 * unit, height: 20 * unit)
            let origin = CGPoint(
                x: (proxy.size.width - drawingSize.width) / 2,
                y: (proxy.size.height - drawingSize.height) / 2
            )

            Canvas(rendersAsynchronously: false) { context, _ in
                for pixel in pixels {
                    context.fill(
                        Path(CGRect(
                            x: origin.x + CGFloat(pixel.x) * unit,
                            y: origin.y + CGFloat(pixel.y) * unit,
                            width: unit,
                            height: unit
                        )),
                        with: .foreground
                    )
                }
            }
        }
    }

    private var pixels: Set<Pixel> {
        switch kind {
        case .nearby:
            return Set(
                person(x: 0, y: 6)
                + person(x: 16, y: 6)
                + bluetooth(x: 11, y: 5)
                + [Pixel(8, 9), Pixel(9, 8), Pixel(9, 10), Pixel(15, 8), Pixel(15, 10), Pixel(16, 9)]
            )
        case .mesh:
            return Set(
                device(x: 1, y: 1)
                + device(x: 10, y: 0)
                + device(x: 19, y: 2)
                + device(x: 4, y: 13)
                + device(x: 16, y: 13)
                + dottedLine(from: Pixel(5, 5), to: Pixel(10, 4))
                + dottedLine(from: Pixel(14, 4), to: Pixel(19, 6))
                + dottedLine(from: Pixel(4, 8), to: Pixel(7, 13))
                + dottedLine(from: Pixel(20, 9), to: Pixel(18, 13))
                + dottedLine(from: Pixel(8, 16), to: Pixel(16, 16))
                + bubble(x: 9, y: 7, tail: .left)
            )
        case .courier:
            return Set(
                device(x: 0, y: 7)
                + device(x: 10, y: 7)
                + device(x: 20, y: 7)
                + dottedLine(from: Pixel(4, 10), to: Pixel(10, 10))
                + dottedLine(from: Pixel(14, 10), to: Pixel(20, 10))
                + [Pixel(8, 9), Pixel(8, 10), Pixel(8, 11), Pixel(18, 9), Pixel(18, 10), Pixel(18, 11)]
                + envelope(x: 8, y: 0)
                + [Pixel(11, 5), Pixel(12, 4), Pixel(13, 5)]
            )
        case .network:
            return Set(
                device(x: 1, y: 1)
                + device(x: 19, y: 1)
                + device(x: 1, y: 13)
                + device(x: 19, y: 13)
                + dottedLine(from: Pixel(5, 4), to: Pixel(19, 4))
                + dottedLine(from: Pixel(4, 8), to: Pixel(4, 13))
                + dottedLine(from: Pixel(20, 8), to: Pixel(20, 13))
                + dottedLine(from: Pixel(5, 16), to: Pixel(19, 16))
                + dottedLine(from: Pixel(5, 7), to: Pixel(19, 13))
            )
        case .identity:
            return Set(
                outline(x: 5, y: 0, width: 14, height: 20)
                + person(x: 8, y: 4)
                + key(x: 10, y: 14)
            )
        case .security:
            return Set(
                shield(x: 5, y: 0)
                + key(x: 9, y: 8)
            )
        case .passcode:
            return Set(
                outline(x: 5, y: 5, width: 14, height: 12)
                + line(from: Pixel(8, 5), to: Pixel(8, 3))
                + line(from: Pixel(16, 5), to: Pixel(16, 3))
                + line(from: Pixel(9, 2), to: Pixel(15, 2))
                + [Pixel(9, 10), Pixel(12, 10), Pixel(15, 10)]
            )
        case .faceID:
            return Set(
                faceFrame(x: 4, y: 1)
                + [Pixel(9, 7), Pixel(15, 7)]
                + line(from: Pixel(12, 8), to: Pixel(12, 12))
                + line(from: Pixel(9, 15), to: Pixel(15, 15))
            )
        case .success:
            return Set(
                resultRing
                + line(from: Pixel(7, 9), to: Pixel(10, 12))
                + line(from: Pixel(10, 12), to: Pixel(16, 6))
            )
        case .failure:
            return Set(
                resultRing
                + line(from: Pixel(11, 5), to: Pixel(11, 10))
                + line(from: Pixel(12, 5), to: Pixel(12, 10))
                + [Pixel(11, 13), Pixel(12, 13)]
            )
        }
    }

    private var resultRing: [Pixel] {
        let upperHalf = line(from: Pixel(8, 1), to: Pixel(15, 1))
            + [Pixel(6, 2), Pixel(7, 2), Pixel(16, 2), Pixel(17, 2)]
            + [Pixel(5, 3), Pixel(18, 3), Pixel(4, 4), Pixel(19, 4)]
            + line(from: Pixel(3, 5), to: Pixel(3, 8))
            + line(from: Pixel(20, 5), to: Pixel(20, 8))
        return upperHalf + upperHalf.map { Pixel($0.x, 17 - $0.y) }
    }

    private func shield(x: Int, y: Int) -> [Pixel] {
        var result = line(from: Pixel(x + 2, y), to: Pixel(x + 12, y))
        result += [Pixel(x + 1, y + 1), Pixel(x + 13, y + 1)]
        result += line(from: Pixel(x, y + 2), to: Pixel(x, y + 9))
        result += line(from: Pixel(x + 14, y + 2), to: Pixel(x + 14, y + 9))
        result += [Pixel(x + 1, y + 10), Pixel(x + 13, y + 10)]
        result += [Pixel(x + 2, y + 11), Pixel(x + 12, y + 11)]
        result += [Pixel(x + 3, y + 12), Pixel(x + 11, y + 12)]
        result += [Pixel(x + 4, y + 13), Pixel(x + 10, y + 13)]
        result += [Pixel(x + 5, y + 14), Pixel(x + 9, y + 14)]
        result += [Pixel(x + 6, y + 15), Pixel(x + 8, y + 15), Pixel(x + 7, y + 16)]
        return result
    }

    private func faceFrame(x: Int, y: Int) -> [Pixel] {
        var result = line(from: Pixel(x, y), to: Pixel(x + 5, y))
        result += line(from: Pixel(x, y), to: Pixel(x, y + 5))
        result += line(from: Pixel(x + 11, y), to: Pixel(x + 16, y))
        result += line(from: Pixel(x + 16, y), to: Pixel(x + 16, y + 5))
        result += line(from: Pixel(x, y + 14), to: Pixel(x, y + 19))
        result += line(from: Pixel(x, y + 19), to: Pixel(x + 5, y + 19))
        result += line(from: Pixel(x + 16, y + 14), to: Pixel(x + 16, y + 19))
        result += line(from: Pixel(x + 11, y + 19), to: Pixel(x + 16, y + 19))
        return result
    }

    private func bubble(x: Int, y: Int, tail: Tail) -> [Pixel] {
        outline(x: x, y: y, width: 8, height: 7)
        + (tail == .left
            ? [Pixel(x + 2, y + 7), Pixel(x + 2, y + 8), Pixel(x + 3, y + 7)]
            : [Pixel(x + 5, y + 7), Pixel(x + 5, y + 8), Pixel(x + 4, y + 7)])
    }

    private func person(x: Int, y: Int) -> [Pixel] {
        outline(x: x + 2, y: y, width: 4, height: 4)
        + line(from: Pixel(x + 1, y + 5), to: Pixel(x + 6, y + 5))
        + line(from: Pixel(x, y + 6), to: Pixel(x + 7, y + 6))
        + [Pixel(x, y + 7), Pixel(x + 7, y + 7)]
    }

    private func key(x: Int, y: Int) -> [Pixel] {
        outline(x: x, y: y, width: 4, height: 4)
        + line(from: Pixel(x + 4, y + 2), to: Pixel(x + 8, y + 2))
        + [Pixel(x + 6, y + 3), Pixel(x + 8, y + 3)]
    }

    private func device(x: Int, y: Int) -> [Pixel] {
        outline(x: x, y: y, width: 4, height: 8)
            + [Pixel(x + 1, y + 6), Pixel(x + 2, y + 6)]
    }

    private func bluetooth(x: Int, y: Int) -> [Pixel] {
        [
            Pixel(x, y), Pixel(x + 1, y + 1), Pixel(x + 2, y + 2),
            Pixel(x + 1, y + 3), Pixel(x, y + 4), Pixel(x + 1, y + 5),
            Pixel(x + 2, y + 6), Pixel(x + 1, y + 7), Pixel(x, y + 8),
            Pixel(x, y + 2), Pixel(x, y + 6)
        ]
    }

    private func envelope(x: Int, y: Int) -> [Pixel] {
        outline(x: x, y: y, width: 8, height: 6)
            + line(from: Pixel(x + 1, y + 1), to: Pixel(x + 4, y + 3))
            + line(from: Pixel(x + 6, y + 1), to: Pixel(x + 4, y + 3))
    }

    private func outline(x: Int, y: Int, width: Int, height: Int) -> [Pixel] {
        line(from: Pixel(x + 1, y), to: Pixel(x + width - 2, y))
        + line(from: Pixel(x, y + 1), to: Pixel(x, y + height - 2))
        + line(from: Pixel(x + width - 1, y + 1), to: Pixel(x + width - 1, y + height - 2))
        + line(from: Pixel(x + 1, y + height - 1), to: Pixel(x + width - 2, y + height - 1))
    }

    private func line(from start: Pixel, to end: Pixel) -> [Pixel] {
        let steps = max(abs(end.x - start.x), abs(end.y - start.y))
        guard steps > 0 else { return [start] }
        return (0...steps).map { step in
            Pixel(
                start.x + (end.x - start.x) * step / steps,
                start.y + (end.y - start.y) * step / steps
            )
        }
    }

    private func dottedLine(from start: Pixel, to end: Pixel) -> [Pixel] {
        line(from: start, to: end).enumerated().compactMap { index, pixel in
            index.isMultiple(of: 2) ? pixel : nil
        }
    }

    private enum Tail { case left, right }

    private struct Pixel: Hashable {
        let x: Int
        let y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }
}
