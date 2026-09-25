import SwiftUI

private struct ShumPresentPeerPhotoKey: EnvironmentKey {
    static let defaultValue: ((UIImage) -> Void)? = nil
}

extension EnvironmentValues {
    var shumPresentPeerPhoto: ((UIImage) -> Void)? {
        get { self[ShumPresentPeerPhotoKey.self] }
        set { self[ShumPresentPeerPhotoKey.self] = newValue }
    }
}

/// Keeps photo presentation outside the conversation's modal lifecycle.
/// FullScreenPhotoView owns the profile's animation and safe-area layout.
struct ShumPeerPhotoPresentationHost: ViewModifier {
    @State private var image: UIImage?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .environment(\.shumPresentPeerPhoto, { image in
                guard !isPresented else { return }
                self.image = image
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isPresented = true }
            })
            .accessibilityHidden(isPresented)
            .overlay {
                if isPresented, let image {
                    FullScreenPhotoView(isPresented: $isPresented) {
                        Image(uiImage: image).resizable().scaledToFit()
                    }
                    // Only the viewer's black background ignores safe areas.
                    // Extending the whole viewer puts Close under the status bar.
                    .accessibilityAddTraits(.isModal)
                }
            }
            .onChange(of: isPresented) { visible in
                if !visible { image = nil }
            }
    }
}
