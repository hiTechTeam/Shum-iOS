#if os(iOS)
import SwiftUI

struct ShumInitialsAvatar: View {
    @Environment(\.shumThemePalette) private var palette

    let name: String
    let size: CGFloat

    private var initials: String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let value = words.compactMap(\.first).map(String.init).joined()
        return value.isEmpty ? "?" : value.uppercased()
    }

    private var seed: Int {
        name.unicodeScalars.reduce(17) { partial, scalar in
            (partial &* 31 &+ Int(scalar.value)) & 0x7fff_ffff
        }
    }

    var body: some View {
        ZStack {
            Canvas { context, canvasSize in
                let columns = 4
                let tileWidth = canvasSize.width / CGFloat(columns)
                let tileHeight = canvasSize.height / CGFloat(columns)

                context.fill(
                    Path(CGRect(origin: .zero, size: canvasSize)),
                    with: .color(palette.accent)
                )

                for row in 0 ..< columns {
                    for column in 0 ..< columns {
                        let value = abs(seed &+ row &* 11 &+ column &* 17 &+ row &* column &* 7) % 5
                        guard value > 0 else { continue }
                        let opacity = [0.0, 0.10, 0.18, 0.27, 0.38][value]
                        let rect = CGRect(
                            x: CGFloat(column) * tileWidth,
                            y: CGFloat(row) * tileHeight,
                            width: tileWidth + 0.5,
                            height: tileHeight + 0.5
                        )
                        context.fill(
                            Path(rect),
                            with: .color(palette.canvas.opacity(opacity))
                        )
                    }
                }
            }

            Text(initials)
                .font(.system(size: size * 0.39, weight: .semibold, design: .rounded))
                .foregroundStyle(palette.accentForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .padding(.horizontal, size * 0.08)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .contentShape(Circle())
        .accessibilityHidden(true)
    }
}

struct ShumAvatar: View {
    let name: String
    let size: CGFloat
    var nearby = false
    var imageData: Data?
    var body: some View {
        Group {
            if let data = imageData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                ShumInitialsAvatar(name: name, size: size)
            }
        }
            .overlay(alignment: .bottomTrailing) {
                if nearby {
                    Circle().fill(Color(uiColor: .systemGreen)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2.5))
                }
            }.accessibilityHidden(true)
    }
}
#endif
