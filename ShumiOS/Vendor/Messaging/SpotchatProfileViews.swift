#if os(iOS)
import PhotosUI
import SwiftUI

struct SpotchatPeerProfileSheet: View {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShumPeerCard(runtime: runtime, peer: peer) { dismiss() }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
    }
}

struct SpotchatPhotoViewer: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss
    @State private var zoom: CGFloat = 1
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFit()
                    .scaleEffect(zoom)
                    .gesture(MagnificationGesture().onChanged { zoom = min(3, max(1, $0)) }.onEnded { _ in withAnimation { zoom = 1 } })
                    .onTapGesture(count: 2) { withAnimation { zoom = zoom > 1 ? 1 : 2 } }
                    .accessibilityLabel("Фото профиля")
            }
        }.overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(shumSymbol: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
            }.padding().accessibilityLabel("Закрыть фото")
        }
    }
}
#endif
