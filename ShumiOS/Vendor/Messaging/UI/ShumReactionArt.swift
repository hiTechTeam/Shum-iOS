#if os(iOS)
import SwiftUI
import UIKit

/// Pixel reactions drawn on the same 12×12 grid as the tab icons.
@MainActor
enum ShumReactionArt {
    private static let like = [
        "............", "......YY....", ".....YYY....", ".....YYY....", "....YYY.....", "GG.YYYYYYYY.",
        "GG.YYYYYYYYY", "GG.YYYYYYYO.", "GG.YYYYYYYYY", "GG.YYYYYYYO.", "GG.YYYYYYY..", "............"
    ]
    private static let hand: [Character: UInt32] = ["G": 0x30D158, "Y": 0xFFC93C, "O": 0xE59A1C]

    static func pixels(for reaction: ShumReaction) -> (rows: [String], colors: [Character: UInt32]) {
        switch reaction {
        case .heart:
            return ([
                "............", "..RR....RR..", ".RPRR..RRRR.", "RPRRRRRRRRRR", "RRRRRRRRRRRR", "RRRRRRRRRRRR",
                ".RRRRRRRRRR.", "..RRRRRRRR..", "...RRRRRR...", "....RRRR....", ".....RR.....", "............"
            ], ["R": 0xFF4245, "P": 0xFF9A9C])
        case .like:
            return (like, hand)
        case .dislike:
            return (Array(like.reversed()), hand)
        case .laugh:
            return ([
                "....YYYY....", "..YYYYYYYY..", ".YYYYYYYYYY.", ".YDDYYYYDDY.", "BYYYYYYYYYYB", "BYYYYYYYYYYB",
                "YYDDDDDDDDYY", "YYDWWWWWWDYY", ".YDMMMMMMDY.", ".YYDDDDDDYY.", "..YYYYYYYY..", "....YYYY...."
            ], ["Y": 0xFFC93C, "D": 0x3B2A12, "W": 0xFFFFFF, "M": 0x8C2A1E, "B": 0x5AC8FA])
        case .fire:
            return ([
                ".....R......", ".....RR.....", "....RRR.....", "...RRRR..R..", "..RRROR.RR..", "..RROORRRR..",
                ".RROOOORRRR.", ".RROOYOOORR.", ".RROYYYOORR.", ".RROYYYYORR.", "..RROYYORR..", "...RRRRRR..."
            ], ["R": 0xFF4245, "O": 0xFF8A1F, "Y": 0xFFD23F])
        case .coffin:
            return ([
                "....DDDD....", "...DWWWWD...", "..DWWCCWWD..", ".DWWWCCWWWD.", ".DWCCCCCCWD.", ".DWWWCCWWWD.",
                "..DWWCCWWD..", "..DWWCCWWD..", "..DWWWWWWD..", "...DWWWWD...", "...DWWWWD...", "....DDDD...."
            ], ["D": 0x4A2E14, "W": 0x8B5A2B, "C": 0xE8C9A0])
        case .hundred:
            return ([
                "............", "..R.RRR.RRR.", ".RR.R.R.R.R.", "..R.R.R.R.R.", "..R.R.R.R.R.", "..R.R.R.R.R.",
                "..R.RRR.RRR.", "............", ".RRRRRRRRRR.", "............", "..RRRRRRRR..", "............"
            ], ["R": 0xFF4245])
        case .horror:
            return ([
                "....LLLL....", "..LLLLLLLL..", ".LLLLLLLLLL.", ".YWKYYYYKWY.", "YYWWYYYYWWYY", "YYYYYYYYYYYY",
                "YYYYYMMYYYYY", "YHYYMMMMYYHY", "HHYYMMMMYYHH", "HH.YYMMYY.HH", "....YYYY....", "............"
            ], ["L": 0x7FB2FF, "Y": 0xFFC93C, "W": 0xFFFFFF, "K": 0x2A1A0A, "M": 0x3B1010, "H": 0xE59A1C])
        }
    }

    static func name(for reaction: ShumReaction) -> String {
        switch reaction {
        case .heart: "Сердце".localized
        case .like: "Нравится".localized
        case .dislike: "Не нравится".localized
        case .laugh: "Смешно".localized
        case .fire: "Огонь".localized
        case .coffin: "Гроб".localized
        case .hundred: "100"
        case .horror: "Кошмар".localized
        }
    }

    private static var cache: [String: UIImage] = [:]

    /// Crisp squares at any size; the image keeps its own colors in menus and buttons.
    static func image(for reaction: ShumReaction, size: CGFloat) -> UIImage {
        let key = "\(reaction.rawValue)-\(size)"
        if let cached = cache[key] { return cached }
        let art = pixels(for: reaction)
        let cell = size / 12
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            for (y, row) in art.rows.enumerated() {
                for (x, symbol) in row.enumerated() {
                    guard let rgb = art.colors[symbol] else { continue }
                    UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                            blue: CGFloat(rgb & 0xFF) / 255, alpha: 1).setFill()
                    // Slight overlap hides seams between cells at fractional scales.
                    context.fill(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell + 0.3, height: cell + 0.3))
                }
            }
        }.withRenderingMode(.alwaysOriginal)
        cache[key] = image
        return image
    }
}

struct ShumReactionIcon: View {
    let reaction: ShumReaction
    var size: CGFloat = 18

    var body: some View {
        Image(uiImage: ShumReactionArt.image(for: reaction, size: size))
            .interpolation(.none)
            .frame(width: size, height: size)
            .accessibilityLabel(ShumReactionArt.name(for: reaction))
    }
}
#endif
