#if os(iOS)
import SwiftUI

struct SpotchatAvatar: View {
    let name: String
    let size: CGFloat
    var nearby = false
    var imageData: Data?
    private var color: Color {
        let palette: [Color] = [.blue, .indigo, .teal, .purple, .orange]
        let index = name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }
        return palette[index]
    }
    var body: some View {
        Text(name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
            .font(.system(size: size * 0.36, weight: .medium, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(LinearGradient(colors: [color.opacity(0.6), color], startPoint: .top, endPoint: .bottom), in: Circle())
            .overlay {
                if let data = imageData, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
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
