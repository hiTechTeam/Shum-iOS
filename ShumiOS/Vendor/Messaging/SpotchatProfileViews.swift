#if os(iOS)
import PhotosUI
import SwiftUI

struct SpotchatPeerProfileSheet: View {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    @Environment(\.dismiss) private var dismiss
    @State private var showPhoto = false
    private var profile: SpotchatProfile? { runtime.profile(for: peer.id) }
    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            GeometryReader { geometry in
                // Same available-space calculation as Telescan's ProfileSheetView.
                let availableSize = max(0, min(geometry.size.width, geometry.size.height) - 24)
                let avatarSize = availableSize * 0.9 * 1.04
                Button { showPhoto = profile?.avatar != nil } label: {
                    SpotchatAvatar(name: runtime.displayName(peer), size: avatarSize, imageData: profile?.avatar)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .offset(y: -10)
                .accessibilityLabel("Посмотреть фото собеседника")
            }
            VStack(spacing: 0) {
                VStack(spacing: 3) {
                    Text(runtime.displayName(peer)).font(.title.bold()).multilineTextAlignment(.center)
                    HStack(spacing: 5) {
                        Circle().fill(runtime.isNearby(peer.id) ? Color.green : Color.secondary).frame(width: 6, height: 6)
                        Text(runtime.isBlocked(peer.id) ? "Заблокирован" : (runtime.isNearby(peer.id) ? "Рядом" : "Сейчас не рядом"))
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .offset(y: -10)
                if let bio = profile?.bio, !bio.isEmpty {
                    Text(String(bio.prefix(SpotchatProfile.maxBioCharacters)))
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 48)
                } else {
                    Color.clear.frame(height: 48).accessibilityHidden(true)
                }
                if runtime.profiles.loading.contains(peer.id) {
                    HStack(spacing: 6) { ProgressView(); Text("Загружаем фото…").font(.caption).foregroundStyle(.secondary) }
                } else if runtime.profiles.failed.contains(peer.id), runtime.isNearby(peer.id) {
                    Button("Обновить профиль") { runtime.profiles.refresh(peer.id) }.font(.caption)
                }
            }
            .frame(maxWidth: 360)
            .padding(.horizontal, 20)
            // Preserve Telescan's 50 pt footer space without its message button.
            .padding(.bottom, 50)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
        .padding(.top, 60)
        .offset(y: -10)
        .background(Color(.systemBackground))
        .overlay(alignment: .topTrailing) {
            if let card = runtime.permanent?.card(for: peer.id) {
                SpotchatContactActionsMenu(runtime: runtime, card: card, onDelete: { dismiss() })
                    .padding(.trailing, 16).padding(.top, 12)
            }
        }
        .presentationDetents([.medium]).presentationDragIndicator(.visible)
        .onAppear { if profile == nil || runtime.profiles.failed.contains(peer.id) { runtime.profiles.refresh(peer.id) } }
        .fullScreenCover(isPresented: $showPhoto) {
            if let data = profile?.avatar { SpotchatPhotoViewer(data: data) }
        }
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
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
            }.padding().accessibilityLabel("Закрыть фото")
        }
    }
}
#endif
