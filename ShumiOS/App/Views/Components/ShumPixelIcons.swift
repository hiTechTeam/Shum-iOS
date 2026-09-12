import SwiftUI
import UIKit

/// Shared pixel grid for app-owned icons. Photos and system pickers keep their own rendering.
enum ShumPixelSymbols {
    private static let cache = NSCache<NSString, UIImage>()
    private static let grids: [String: [String]] = [
        "plus": ["00000011000000","00000011000000","00000011000000","00000011000000","00000011000000","00000011000000","11111111111111","11111111111111","00000011000000","00000011000000","00000011000000","00000011000000","00000011000000","00000011000000"],
        "xmark": ["11000000000011","11100000000111","01110000001110","00111000011100","00011100111000","00001111110000","00000111100000","00000111100000","00001111110000","00011100111000","00111000011100","01110000001110","11100000000111","11000000000011"],
        "magnifyingglass": ["00011111000000","00111111100000","01100000110000","11000000011000","11000000011000","11000000011000","11000000011000","01100000110000","00111111100000","00011111110000","00000000111000","00000000011100","00000000001110","00000000000111"],
        "trash": ["00000111100000","00001111110000","00111111111100","00111111111100","00010000001000","00010100101000","00010100101000","00010100101000","00010100101000","00010100101000","00010100101000","00010000001000","00011111111000","00001111110000"],
        "block": ["00001111110000","00111111111100","01110000001110","01110000001110","11011000000011","11001100000011","11000110000011","11000011000011","11000001100011","11000000110011","01110000011110","01110000001110","00111111111100","00001111110000"],
        "chevron.right": ["00011000000000","00011100000000","00001110000000","00000111000000","00000011100000","00000001110000","00000000111000","00000000111000","00000001110000","00000011100000","00000111000000","00001110000000","00011100000000","00011000000000"],
        "checkmark": ["00000000000000","00000000000011","00000000000111","00000000001110","00000000011100","00000000111000","11000001110000","11100011100000","01110111000000","00111110000000","00011100000000","00001000000000","00000000000000","00000000000000"]
    ]

    static func image(named name: String) -> UIImage? {
        if let cached = cache.object(forKey: name as NSString) { return cached }
        let key: String
        if name.hasPrefix("trash") { key = "trash" }
        else if name.contains("badge.xmark") || name == "hand.raised.slash" { key = "block" }
        else if name == "chevron.left" { key = "chevron.right" }
        else { key = name }
        let cells: [[Bool]]
        if let grid = grids[key] {
            cells = grid.map { row in
                let bits = row.map { $0 == "1" }
                return name == "chevron.left" ? Array(bits.reversed()) : bits
            }
        } else {
            guard let symbol = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)) else { return nil }
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let sample = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18), format: format).image { _ in
                let ratio = min(16 / symbol.size.width, 16 / symbol.size.height)
                let size = CGSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
                symbol.withTintColor(.black, renderingMode: .alwaysOriginal).draw(in: CGRect(x: (18-size.width)/2, y: (18-size.height)/2, width: size.width, height: size.height))
            }
            guard let cg = sample.cgImage else { return nil }
            var bytes = [UInt8](repeating: 0, count: 18 * 18 * 4)
            let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: 18, height: 18, bitsPerComponent: 8, bytesPerRow: 72, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(cg, in: CGRect(x: 0, y: 0, width: 18, height: 18))
                return true
            }
            guard rendered else { return nil }
            cells = (0..<18).map { y in (0..<18).map { x in bytes[(y * 18 + x) * 4 + 3] >= 96 } }
        }
        let format = UIGraphicsImageRendererFormat(); format.scale = 3
        let icon = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format).image { renderer in
            renderer.cgContext.setShouldAntialias(false)
            UIColor.black.setFill()
            let step = 24 / CGFloat(cells.count)
            for (y, row) in cells.enumerated() {
                for (x, filled) in row.enumerated() where filled {
                    renderer.fill(CGRect(x: CGFloat(x)*step, y: CGFloat(y)*step, width: step, height: step))
                }
            }
        }.withRenderingMode(.alwaysTemplate)
        cache.setObject(icon, forKey: name as NSString)
        return icon
    }
}

extension Image {
    init(shumSymbol name: String) {
        self.init(uiImage: ShumPixelSymbols.image(named: name) ?? UIImage())
        self = self.renderingMode(.template).interpolation(.none)
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: LocalizedStringKey, shumSymbol: String) {
        self.init { Text(title) } icon: { Image(shumSymbol: shumSymbol) }
    }
    init<S: StringProtocol>(_ title: S, shumSymbol: String) {
        self.init { Text(title) } icon: { Image(shumSymbol: shumSymbol) }
    }
}

struct ShumSwipeLabel: View {
    let title: String
    let symbol: String
    var body: some View {
        Label {
            Text(title).foregroundStyle(.black)
        } icon: {
            Image(uiImage: (ShumPixelSymbols.image(named: symbol) ?? UIImage())
                .withTintColor(.black, renderingMode: .alwaysOriginal))
                .renderingMode(.original)
                .interpolation(.none)
        }
    }
}
