#if os(iOS)
import ShumCore
import SwiftUI
import UIKit

/// Shum-Core's sticker sets: titles, names and the words they stand for.
/// Sets of phrases are stickers only; the rest are reactions too.
final class ShumStickerCatalog: @unchecked Sendable {
    struct Sticker: Decodable { let id: String; let emoji: String; let word: String }
    struct Set: Decodable { let section: String; let title: String; let reactions: Bool; let kinds: [Sticker] }

    static let shared = ShumStickerCatalog()
    let sets: [Set]
    let reactionIDs: Swift.Set<String>
    let reactions: [ShumReaction]
    private let byID: [String: Sticker]

    private init() {
        sets = (try? JSONDecoder().decode([Set].self, from: Data(reactionPool().utf8))) ?? []
        let reactionSets = sets.filter(\.reactions)
        reactionIDs = Swift.Set(reactionSets.flatMap { $0.kinds.map(\.id) })
        byID = Dictionary(sets.flatMap(\.kinds).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Not through ShumReaction(rawValue:): that asks this catalog, still
        // being made, and would never return.
        reactions = reactionSets.flatMap(\.kinds).map { ShumReaction(catalogName: $0.id) }
    }

    func sticker(_ id: String) -> Sticker? { byID[id] }
}

/// Reactions in Shum's pixels, drawn from Shum-Core's sets: emoji on a
/// 16-cell grid and characters on a 32-cell one.
@MainActor
enum ShumReactionArt {
    /// The word a reaction stands for, translated where Shum has it; in
    /// other languages without one, its emoji.
    static func name(for reaction: ShumReaction) -> String {
        guard let sticker = ShumStickerCatalog.shared.sticker(reaction.rawValue) else { return reaction.rawValue }
        let word = sticker.word.prefix(1).uppercased() + sticker.word.dropFirst()
        let translated = word.localized
        let russian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        return translated != word || russian ? translated : sticker.emoji
    }

    /// The sets of reactions, in Shum-Core's order, with their titles.
    static let sections: [(title: String, reactions: [ShumReaction])] =
        ShumStickerCatalog.shared.sets.filter(\.reactions).map { set in
            (set.title.localized, set.kinds.compactMap { ShumReaction(rawValue: $0.id) })
        }

    private static var cache: [String: UIImage] = [:]

    /// Crisp squares at any size; the image keeps its own colors in menus and buttons.
    static func image(for reaction: ShumReaction, size: CGFloat) -> UIImage {
        image(sticker: reaction.rawValue, size: size)
    }

    /// Any sticker of Shum's sets, reactions and phrases alike.
    static func image(sticker id: String, size: CGFloat) -> UIImage {
        picture(key: "\(id)-\(size)", size: size) { [UInt8](reactionPixels(kind: id)) }
    }

    /// A set's picture for the row of sets.
    static func icon(set id: String, size: CGFloat) -> UIImage {
        picture(key: "set-\(id)-\(size)", size: size) { [UInt8](stickerSetPixels(set: id)) }
    }

    private static func picture(key: String, size: CGFloat, rgba: () -> [UInt8]) -> UIImage {
        if let cached = cache[key] { return cached }
        let rgba = rgba()
        let side = Int(Double(rgba.count / 4).squareRoot())
        let cell = size / CGFloat(max(side, 1))
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            for index in 0..<(side * side) where rgba[index * 4 + 3] > 0 {
                let pixel = index * 4
                UIColor(red: CGFloat(rgba[pixel]) / 255, green: CGFloat(rgba[pixel + 1]) / 255,
                        blue: CGFloat(rgba[pixel + 2]) / 255, alpha: CGFloat(rgba[pixel + 3]) / 255).setFill()
                // Slight overlap hides seams between cells at fractional scales.
                context.fill(CGRect(x: CGFloat(index % side) * cell, y: CGFloat(index / side) * cell,
                                    width: cell + 0.3, height: cell + 0.3))
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
