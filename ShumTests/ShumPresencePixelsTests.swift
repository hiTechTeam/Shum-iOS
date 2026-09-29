import SwiftUI
import Testing
import UIKit
@testable import Shum

/// The "in chat" mark keeps one stable pattern per contact and stays small
/// enough to sit on an avatar corner.
@Suite("Presence pixels")
@MainActor
struct ShumPresencePixelsTests {
    @Test func eachContactKeepsItsOwnFourPixelPattern() {
        let pattern = ShumPresencePixels.pattern(for: "peer-a")
        #expect(pattern.count == 4)
        #expect(pattern.allSatisfy { (0..<9).contains($0) })
        #expect(pattern == ShumPresencePixels.pattern(for: "peer-a"))
        let variety = Set((0..<50).map { ShumPresencePixels.pattern(for: "peer-\($0)") })
        #expect(variety.count > 10)
    }

    /// While typing the grid pulses at random with at least one lit pixel;
    /// when typing stops it freezes in place at full brightness.
    @Test func typingPulsesAndFreezesWhenItStops() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let levels = ShumTypingPixels.randomLevels(using: &generator)
            #expect(levels.count == 9 && levels.contains { $0 > 0 })
            #expect(levels.allSatisfy { $0 == 0 || (0.35...1).contains($0) })
        }
        let pixels = ShumTypingPixels()
        pixels.reduceMotion = { false }
        let seed = "peer-a"
        #expect(pixels.levels(for: seed) == ShumTypingPixels.baseLevels(for: seed))
        pixels.update(typing: [seed])
        var seen = Set<[Double]>()
        for _ in 0..<20 { pixels.step(); seen.insert(pixels.levels(for: seed)) }
        #expect(seen.count > 1)
        let lastFrame = pixels.levels(for: seed)
        pixels.update(typing: [])
        let frozen = pixels.levels(for: seed)
        #expect(frozen == lastFrame.map { $0 > 0 ? 1 : 0 })
        pixels.step()
        #expect(pixels.levels(for: seed) == frozen)
    }

    @Test func reduceMotionKeepsPixelsStill() {
        let pixels = ShumTypingPixels()
        pixels.reduceMotion = { true }
        pixels.update(typing: ["peer-a"])
        pixels.step()
        #expect(pixels.levels(for: "peer-a") == ShumTypingPixels.baseLevels(for: "peer-a"))
        pixels.update(typing: [])
    }

    @Test func badgeFitsTheAvatarCorner() throws {
        let renderer = ImageRenderer(content: ShumPresenceBadge(seed: "peer-a"))
        renderer.scale = 3
        let image = try #require(renderer.uiImage)
        #expect(image.size.width <= 18 && image.size.height <= 16)

        // Optional visual check of the real views: SHUM_RENDER_DIR=/path.
        guard let directory = ProcessInfo.processInfo.environment["SHUM_RENDER_DIR"] else { return }
        for scheme in [ColorScheme.light, .dark] {
            let sample = PresenceSample().environment(\.colorScheme, scheme)
            let preview = ImageRenderer(content: sample)
            preview.scale = 3
            let data = try #require(preview.uiImage?.pngData())
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("presence-\(scheme).png"))
        }
    }
}

private struct PresenceSample: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 2) {
                Text("Ольга").font(.system(size: 17, weight: .semibold))
                HStack(spacing: 4) {
                    ShumPresencePixels(seed: "peer-a", offColor: Color.secondary.opacity(0.3))
                    Text("в чате").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 18) {
                ForEach(["peer-a", "peer-b", "peer-c", "peer-d"], id: \.self) { seed in
                    Circle().fill(Color.teal).frame(width: 58, height: 58)
                        .overlay(alignment: .bottomTrailing) {
                            ShumPresenceBadge(seed: seed).offset(x: 2, y: 1)
                        }
                }
            }
        }
        .padding(24)
        .foregroundStyle(scheme == .dark ? .white : .black)
        .background(scheme == .dark ? Color(white: 0.07) : Color(white: 0.97))
    }
}
