#if os(iOS)
import SwiftUI
import UIKit

/// "In chat" mark in the pixel style of Shum avatars: a 3×3 grid with a few
/// lit pixels in the theme accent. Each contact keeps its own stable pattern.
struct ShumPresencePixels: View {
    let seed: String
    var cell: CGFloat = 2
    var gap: CGFloat = 1
    var offColor: Color = .clear
    /// On the dark avatar plate, an accent too dark to see is drawn white.
    var onDarkPlate = false
    @Environment(\.shumThemePalette) private var palette

    static func litColor(accent: UIColor, onDarkPlate: Bool) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        accent.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return onDarkPlate && luminance < 0.25 ? .white : Color(uiColor: accent)
    }

    /// Four distinct cells chosen by a stable FNV-1a hash of the seed.
    static func pattern(for seed: String) -> Set<Int> {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        var cells = Array(0..<9)
        for index in stride(from: cells.count - 1, to: 0, by: -1) {
            hash = hash &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            cells.swapAt(index, Int((hash >> 33) % UInt64(index + 1)))
        }
        return Set(cells.prefix(4))
    }

    @ObservedObject private var typing = ShumTypingPixels.shared

    var body: some View {
        let levels = typing.levels(for: seed)
        let lit = Self.litColor(accent: palette.accentUIColor, onDarkPlate: onDarkPlate)
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<3, id: \.self) { column in
                        ZStack {
                            Rectangle().fill(offColor)
                            Rectangle().fill(lit).opacity(levels[row * 3 + column])
                        }
                        .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.16), value: levels)
        .accessibilityHidden(true)
    }
}

/// While a contact types, its grid pulses at random as if something keeps
/// stirring it. When typing stops, the lit pixels freeze where they are.
/// Header and chat list read the same state, so they move together.
@MainActor
final class ShumTypingPixels: ObservableObject {
    static let shared = ShumTypingPixels()
    static let interval: TimeInterval = 0.18

    /// Brightness of each of the nine cells per contact; 0 is off.
    @Published private(set) var levelsBySeed: [String: [Double]] = [:]
    var reduceMotion: () -> Bool = { UIAccessibility.isReduceMotionEnabled }
    private var typing: Set<String> = []
    private var timer: Timer?

    func levels(for seed: String) -> [Double] {
        levelsBySeed[seed] ?? Self.baseLevels(for: seed)
    }

    static func baseLevels(for seed: String) -> [Double] {
        let lit = ShumPresencePixels.pattern(for: seed)
        return (0..<9).map { lit.contains($0) ? 1 : 0 }
    }

    func update(typing seeds: Set<String>) {
        for seed in typing.subtracting(seeds) { freeze(seed) }
        typing = seeds
        guard !typing.isEmpty, !reduceMotion() else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func step() {
        guard !reduceMotion() else { return }
        var generator = SystemRandomNumberGenerator()
        for seed in typing { levelsBySeed[seed] = Self.randomLevels(using: &generator) }
    }

    /// Random pulse: each cell is off or lit at a random brightness, and at
    /// least one cell is always lit.
    static func randomLevels<G: RandomNumberGenerator>(using generator: inout G) -> [Double] {
        var levels = (0..<9).map { _ in
            Bool.random(using: &generator) ? Double.random(in: 0.35...1, using: &generator) : 0
        }
        if !levels.contains(where: { $0 > 0 }) {
            levels[Int.random(in: 0..<9, using: &generator)] = Double.random(in: 0.35...1, using: &generator)
        }
        return levels
    }

    /// Stops in the current position with the lit cells at full brightness.
    private func freeze(_ seed: String) {
        guard let current = levelsBySeed[seed] else { return }
        levelsBySeed[seed] = current.map { $0 > 0 ? 1 : 0 }
    }
}

/// A translucent plate with the "in chat" pixels, laid over an avatar corner.
struct ShumPresenceBadge: View {
    let seed: String
    private let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)

    var body: some View {
        ShumPresencePixels(seed: seed, cell: 3, gap: 0.5, offColor: .white.opacity(0.16), onDarkPlate: true)
            .padding(.horizontal, 3.5)
            .padding(.vertical, 2.5)
            .background(Color.black.opacity(0.45), in: shape)
            .overlay { shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5) }
    }
}
#endif
