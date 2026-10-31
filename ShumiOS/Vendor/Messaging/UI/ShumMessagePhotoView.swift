#if os(iOS)
import SwiftUI

/// A message's photo inside its bubble: the picture once every part is here,
/// a ring while parts are coming, a note when it never came. Its bytes are
/// read from Shum-Core only when the row is shown.
struct ShumMessagePhotoView<Overlay: View>: View {
    let messageID: String
    let photo: ShumMessagePhoto
    let width: CGFloat
    var radius: CGFloat = 18
    var load: ((String) async -> UIImage?)?
    var open: ((UIImage) -> Void)?
    @ViewBuilder var overlay: () -> Overlay
    @Environment(\.shumThemePalette) private var palette
    @State private var image: UIImage?

    /// `cached` gives the photo at once when it was read before, so a row
    /// drawn again keeps its picture instead of flashing the placeholder.
    init(messageID: String, photo: ShumMessagePhoto, width: CGFloat, radius: CGFloat = 18,
         cached: ((String) -> UIImage?)? = nil,
         load: ((String) async -> UIImage?)?, open: ((UIImage) -> Void)?,
         @ViewBuilder overlay: @escaping () -> Overlay) {
        self.messageID = messageID
        self.photo = photo
        self.width = width
        self.radius = radius
        self.load = load
        self.open = open
        self.overlay = overlay
        _image = State(initialValue: photo.state == .ready ? cached?(messageID) : nil)
    }

    /// The photo's own proportions, kept within sensible bounds in a chat.
    private var height: CGFloat {
        guard photo.width > 0 else { return width * 0.75 }
        let natural = width * CGFloat(photo.height) / CGFloat(photo.width)
        return min(max(natural, width * 0.5), width * 1.35)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                placeholder
            }
            overlay().padding(8)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onTapGesture {
            if let image { open?(image) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(image == nil ? [] : .isButton)
        .task(id: "\(messageID)-\(photo.state)") {
            guard photo.state == .ready, image == nil else { return }
            image = await load?(messageID)
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            switch photo.state {
            case .missing:
                Image(systemName: "photo")
                    .font(.system(size: 26, weight: .regular))
                    .foregroundStyle(.secondary)
                Text("Фото не дошло".localized)
            case .loading, .ready:
                ProgressView()
                    .controlSize(.large)
                    .tint(palette.accent)
                Text("Фото загружается".localized)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .frame(width: width, height: height)
        .background(Color(.secondarySystemFill))
    }

    private var accessibilityText: String {
        switch photo.state {
        case .ready: return "Фото".localized
        case .loading: return "Фото загружается".localized
        case .missing: return "Фото не дошло".localized
        }
    }
}
#endif
