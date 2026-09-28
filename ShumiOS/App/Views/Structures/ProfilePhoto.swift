import SwiftUI

struct ProfilePhotoView: View {
    @ObservedObject var viewModel: ProfilePhotoViewModel
    let name: String
    @State private var showPixelAvatarGenerator = false
    private let imageSize: CGFloat = 132

    var body: some View {
        VStack(spacing: 14) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showPixelAvatarGenerator = true
            } label: {
                if let uiImage = viewModel.uiImage {
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: imageSize, height: imageSize)
                        .clipShape(Circle())
                } else {
                    ShumInitialsAvatar(name: name, size: imageSize)
                }
            }
            .buttonStyle(.plain)

            Button("Сменить аватар".localized) {
                showPixelAvatarGenerator = true
            }
            .font(.system(size: 16, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .sheet(isPresented: $showPixelAvatarGenerator) {
            PixelAvatarGeneratorSheet(currentSeed: viewModel.avatarSeed) { seed in
                if viewModel.usePixelAvatar(seed: seed) {
                    showPixelAvatarGenerator = false
                }
            }
            .presentationDetents([.height(470)])
            .presentationDragIndicator(.visible)
        }
        .alert("local.photo.save.error", isPresented: $viewModel.saveFailed) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
        }
    }
}

private struct PixelAvatarGeneratorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let currentSeed: UInt64?
    let onUse: (UInt64) -> Void
    @State private var seed = UInt64.random(in: UInt64.min...UInt64.max)

    init(currentSeed: UInt64?, onUse: @escaping (UInt64) -> Void) {
        self.currentSeed = currentSeed
        self.onUse = onUse
        _seed = State(initialValue: currentSeed ?? UInt64.random(in: UInt64.min...UInt64.max))
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Аватар".localized)
                    .font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Inc.Common.close.localized)
            }

            Image(uiImage: ShumPixelAvatarGenerator.image(seed: seed))
                .resizable()
                .interpolation(.none)
                .frame(width: 184, height: 184)
                .clipShape(Circle())
                .accessibilityLabel("Предпросмотр аватара".localized)

            Text("Найди аватар себе по душе. Свой характер, свой стиль.".localized)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                var next = UInt64.random(in: UInt64.min...UInt64.max)
                if next == seed { next &+= 1 }
                seed = next
            } label: {
                Label("Другой вариант".localized, systemImage: "arrow.clockwise")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)

            Button { onUse(seed) } label: {
                Text("Поставить на аватар".localized)
            }
            .buttonStyle(ShumPrimaryButtonStyle())
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 24)
        .onAppear {
            seed = currentSeed ?? UInt64.random(in: UInt64.min...UInt64.max)
        }
    }
}

struct FullScreenPhotoView<Content: View>: View {
    @Binding private var isPresented: Bool
    private let content: Content

    @State private var isVisible = false
    @State private var dismissOffset: CGFloat = 0
    @State private var zoomScale: CGFloat = 1

    init(
        isPresented: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        _isPresented = isPresented
        self.content = content()
    }

    private var dragDismissProgress: CGFloat {
        min(abs(dismissOffset) / 360, 1)
    }

    private var pinchDismissProgress: CGFloat {
        min(max((1 - zoomScale) / 0.3, 0), 1)
    }

    private var dismissProgress: CGFloat {
        max(dragDismissProgress, pinchDismissProgress)
    }

    private var photoScale: CGFloat {
        guard isVisible else { return 0.86 }
        return 1 - (dragDismissProgress * 0.12)
    }

    private var backgroundOpacity: CGFloat {
        guard isVisible else { return 0 }
        return 1 - (dismissProgress * 0.65)
    }

    private var dismissGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard zoomScale == 1,
                      abs(value.translation.height) > abs(value.translation.width) else {
                    return
                }

                dismissOffset = value.translation.height
            }
            .onEnded { value in
                guard zoomScale == 1 else { return }

                let shouldDismiss = abs(value.translation.height) > 120 ||
                    abs(value.predictedEndTranslation.height) > 240

                if shouldDismiss {
                    dismissPhoto(followingDrag: true)
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private func dismissPhoto(followingDrag: Bool = false) {
        withAnimation(.easeInOut(duration: 0.22)) {
            isVisible = false
            if followingDrag {
                let direction: CGFloat = dismissOffset < 0 ? -1 : 1
                dismissOffset = direction * max(abs(dismissOffset), 160)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
            var transaction = Transaction()
            transaction.disablesAnimations = true

            withTransaction(transaction) {
                isPresented = false
            }
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black
                .ignoresSafeArea()
                .opacity(backgroundOpacity)

            ZoomablePhoto(
                content: content,
                onPinchDismiss: { dismissPhoto() },
                scale: $zoomScale
            )
                .offset(y: dismissOffset)
                .scaleEffect(photoScale)
                .opacity(isVisible ? 1 : 0)
                .simultaneousGesture(dismissGesture)

            Button {
                dismissPhoto()
            } label: {
                Text(Inc.Common.close.localized)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(16)
            .opacity(
                isVisible
                    ? max(0.0, 1.0 - Double(dismissProgress * 2))
                    : 0.0
            )
        }
        .background(Color.clear)
        .shumPresentationBackground(.clear)
        .statusBarHidden(true)
        .onAppear {
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                    isVisible = true
                }
            }
        }
    }
}

private struct ZoomablePhoto<Content: View>: View {
    let content: Content
    let onPinchDismiss: () -> Void

    @Binding var scale: CGFloat
    @State private var settledScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var settledOffset: CGSize = .zero
    @State private var contentSize: CGSize = .zero
    @State private var viewportSize: CGSize = .zero

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(settledScale * value, 0.62), 5)

                if scale <= 1 {
                    offset = .zero
                    settledOffset = .zero
                } else {
                    offset = clampedOffset(offset, at: scale)
                }
            }
            .onEnded { _ in
                if scale < 0.84 {
                    onPinchDismiss()
                    return
                }

                if scale < 1 {
                    settledScale = 1

                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        scale = 1
                        offset = .zero
                    }
                    settledOffset = .zero
                    return
                }

                let boundedOffset = clampedOffset(offset, at: scale)
                withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                    offset = boundedOffset
                }
                settledOffset = boundedOffset
                settledScale = scale
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }

                let proposedOffset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
                offset = clampedOffset(proposedOffset, at: scale)
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                let boundedOffset = clampedOffset(offset, at: scale)
                offset = boundedOffset
                settledOffset = boundedOffset
            }
    }

    private func clampedOffset(
        _ proposedOffset: CGSize,
        at currentScale: CGFloat
    ) -> CGSize {
        guard contentSize.width > 0,
              contentSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return .zero
        }

        let horizontalLimit = max(
            (contentSize.width * currentScale - viewportSize.width) / 2,
            0
        )
        let verticalLimit = max(
            (contentSize.height * currentScale - viewportSize.height) / 2,
            0
        )

        return CGSize(
            width: min(max(proposedOffset.width, -horizontalLimit), horizontalLimit),
            height: min(max(proposedOffset.height, -verticalLimit), verticalLimit)
        )
    }

    private func reconcileOffset() {
        let boundedOffset = clampedOffset(offset, at: scale)
        offset = boundedOffset
        settledOffset = boundedOffset
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                content
                    .background {
                        GeometryReader { contentProxy in
                            Color.clear.preference(
                                key: PhotoContentSizePreferenceKey.self,
                                value: contentProxy.size
                            )
                        }
                    }
                    .scaleEffect(scale)
                    .offset(offset)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(magnificationGesture)
            .simultaneousGesture(dragGesture)
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if scale > 1 {
                        scale = 1
                        settledScale = 1
                        offset = .zero
                        settledOffset = .zero
                    } else {
                        scale = 2
                        settledScale = 2
                        offset = .zero
                        settledOffset = .zero
                    }
                }
            }
            .onAppear {
                viewportSize = proxy.size
                reconcileOffset()
            }
            .shumOnChange(of: proxy.size) { _, newSize in
                viewportSize = newSize
                reconcileOffset()
            }
        }
        .onPreferenceChange(PhotoContentSizePreferenceKey.self) { newSize in
            guard newSize.width > 0, newSize.height > 0 else { return }
            contentSize = newSize
            reconcileOffset()
        }
        .clipped()
    }
}

private struct PhotoContentSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let nextSize = nextValue()
        guard nextSize.width > 0, nextSize.height > 0 else { return }
        value = nextSize
    }
}
