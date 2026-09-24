import SwiftUI

private struct ShumPresentPeerCardKey: EnvironmentKey {
    static let defaultValue: ((ShumPeer, @escaping () -> Void) -> Void)? = nil
}

extension EnvironmentValues {
    var shumPresentPeerCard: ((ShumPeer, @escaping () -> Void) -> Void)? {
        get { self[ShumPresentPeerCardKey.self] }
        set { self[ShumPresentPeerCardKey.self] = newValue }
    }
}

/// The card and its backdrop stay inside the navigation stack's capture layer.
/// A native sheet has its own surface/chrome and cannot share that placeholder.
struct ShumPeerCardPresentationHost: ViewModifier {
    @ObservedObject var runtime: ShumRuntime
    @State private var presentation: Presentation?

    private struct Presentation: Identifiable {
        let id = UUID()
        let peer: ShumPeer
        let onDismiss: () -> Void
    }

    func body(content: Content) -> some View {
        content
            .environment(\.shumPresentPeerCard, { peer, onDismiss in
                presentation = Presentation(peer: peer, onDismiss: onDismiss)
            })
            .overlay {
                if let presentation {
                    ShumPeerCardOverlay {
                        ShumPeerCard(
                            runtime: runtime,
                            peer: presentation.peer,
                            verifiesIdentity: true,
                            sharesCaptureCover: true,
                            write: {}
                        )
                    } dismiss: {
                        self.presentation = nil
                        presentation.onDismiss()
                    }
                    .id(presentation.id)
                }
            }
    }
}

private struct ShumPeerCardOverlay<Content: View>: View {
    @Environment(\.shumThemePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder let content: () -> Content
    let dismiss: () -> Void
    @State private var isVisible = false
    @State private var isDismissing = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let height = (geometry.size.height + geometry.safeAreaInsets.top + geometry.safeAreaInsets.bottom) / 2

            ZStack(alignment: .bottom) {
                Color.black.opacity(isVisible ? 0.32 : 0)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)

                content()
                    .padding(.bottom, geometry.safeAreaInsets.bottom)
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .background(palette.canvas)
                    .overlay(alignment: .top) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.45))
                            .frame(width: 36, height: 5)
                            .padding(.top, 8)
                            .accessibilityHidden(true)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
                    .offset(y: isVisible ? dragOffset : height + 40)
                    .simultaneousGesture(dismissGesture)
            }
            .ignoresSafeArea()
        }
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, close)
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
                isVisible = true
            }
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(coordinateSpace: .global)
            .onChanged { value in
                guard !isDismissing,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height > 0
                    ? value.translation.height : value.translation.height * 0.12
            }
            .onEnded { value in
                if value.translation.height > 90 || value.predictedEndTranslation.height > 220 {
                    close()
                } else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func close() {
        guard !isDismissing else { return }
        isDismissing = true
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            isVisible = false
        }
        Task { @MainActor in
            if !reduceMotion { try? await Task.sleep(for: .milliseconds(200)) }
            dismiss()
        }
    }
}
