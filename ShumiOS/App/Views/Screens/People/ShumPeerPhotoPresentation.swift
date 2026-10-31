import SwiftUI

private struct ShumPresentPeerPhotoKey: EnvironmentKey {
    static let defaultValue: ((UIImage) -> Void)? = nil
}

/// A photo from a chat, shown full screen with who sent it and when.
struct ShumChatPhoto {
    let image: UIImage
    let title: String
    let subtitle: String
}

private struct ShumPresentChatPhotoKey: EnvironmentKey {
    static let defaultValue: ((ShumChatPhoto) -> Void)? = nil
}

extension EnvironmentValues {
    var shumPresentPeerPhoto: ((UIImage) -> Void)? {
        get { self[ShumPresentPeerPhotoKey.self] }
        set { self[ShumPresentPeerPhotoKey.self] = newValue }
    }
    var shumPresentChatPhoto: ((ShumChatPhoto) -> Void)? {
        get { self[ShumPresentChatPhotoKey.self] }
        set { self[ShumPresentChatPhotoKey.self] = newValue }
    }
}

/// Keeps photo presentation outside the conversation's modal lifecycle.
/// FullScreenPhotoView owns the profile's animation and safe-area layout.
struct ShumPeerPhotoPresentationHost: ViewModifier {
    @State private var image: UIImage?
    @State private var chatPhoto: ShumChatPhoto?
    @State private var isPresented = false

    private func present(_ image: UIImage, chat: ShumChatPhoto?) {
        guard !isPresented else { return }
        self.image = image
        chatPhoto = chat
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isPresented = true }
    }

    func body(content: Content) -> some View {
        content
            .environment(\.shumPresentPeerPhoto, { present($0, chat: nil) })
            .environment(\.shumPresentChatPhoto, { present($0.image, chat: $0) })
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented, let image {
                    FullScreenPhotoView(isPresented: $isPresented, chat: chatPhoto) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    // Only the viewer's black background ignores safe areas.
                    // Extending the whole viewer puts Close under the status bar.
                    .accessibilityAddTraits(.isModal)
                }
            }
            .onChange(of: isPresented) { visible in
                if !visible { image = nil; chatPhoto = nil }
            }
    }
}
