import SwiftUI
import PhotosUI

struct ProfilePhotoView: View {
    @ObservedObject var viewModel: ProfilePhotoViewModel
    
    @State private var selectedItem: PhotosPickerItem?
    @State private var showPhotoOptions: Bool = false
    @State private var showCameraPicker: Bool = false
    @State private var showGalleryPicker: Bool = false
    @State private var showPhotoPreview: Bool = false
    @State private var tempCameraImage: UIImage?
    
    private let imageSize: CGFloat = 132

    private func openPhotoOptions() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showPhotoOptions = true
    }

    private func openPhotoPreview() {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            showPhotoPreview = true
        }
    }

    private func profilePhoto(_ uiImage: UIImage) -> some View {
        Image(uiImage: uiImage)
            .resizable()
            .scaledToFill()
            .frame(width: imageSize, height: imageSize)
            .clipShape(Circle())
            .contentShape(Circle())
    }

    var body: some View {
        VStack(spacing: 14) {
            Button {
                if let uiImage = viewModel.uiImage {
                    openPhotoPreview()
                } else {
                    openPhotoOptions()
                }
            } label: {
                if let uiImage = viewModel.uiImage {
                    profilePhoto(uiImage)
                } else {
                    viewModel.profileImage
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                        .padding(18)
                        .frame(width: imageSize, height: imageSize)
                        .background(
                            Color(uiColor: .secondarySystemBackground),
                            in: Circle()
                        )
                }
            }
            .buttonStyle(.plain)

            Button(Inc.Profile.changePhoto.localized) {
                openPhotoOptions()
            }
            .font(.system(size: 16, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
        }
        .sheet(isPresented: $showPhotoOptions) {
            ProfilePhotoOptionsSheet(
                image: viewModel.uiImage,
                onClose: { showPhotoOptions = false },
                onCamera: openCamera,
                onGallery: openGallery,
                onDelete: deletePhoto
            )
            .presentationDetents([
                .height(viewModel.uiImage == nil ? 250 : 310)
            ])
            .presentationDragIndicator(.hidden)
        }
        .fullScreenCover(isPresented: $showCameraPicker) {
            ZStack {
                Color.black
                    .ignoresSafeArea()

                CameraPicker(image: $tempCameraImage)
                    .ignoresSafeArea()
                    .onDisappear {
                        if let selected = tempCameraImage {
                            viewModel.updateProfileImage(with: selected)
                        }
                        tempCameraImage = nil
                    }
            }
            .background(Color.black.ignoresSafeArea())
            .presentationBackground(.black)
        }
        .fullScreenCover(isPresented: $showPhotoPreview) {
            if let uiImage = viewModel.uiImage {
                FullScreenPhotoView(isPresented: $showPhotoPreview) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .photosPicker(isPresented: $showGalleryPicker, selection: $selectedItem, matching: .images)
        .onChange(of: selectedItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let uiImg = UIImage(data: data) {
                    viewModel.updateProfileImage(with: uiImg)
                }
            }
        }
    }

    private func openCamera() {
        showPhotoOptions = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showCameraPicker = true
        }
    }

    private func openGallery() {
        showPhotoOptions = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            showGalleryPicker = true
        }
    }

    private func deletePhoto() {
        showPhotoOptions = false
        viewModel.updateProfileImage(with: nil)
    }
}

private struct ProfilePhotoOptionsSheet: View {
    let image: UIImage?
    let onClose: () -> Void
    let onCamera: () -> Void
    let onGallery: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                thumbnail

                Text(Inc.Profile.changePhotoTitle.localized)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)

                Spacer(minLength: 8)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .background(
                            Color(uiColor: .tertiarySystemFill),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Inc.Common.close.localized)
            }

            VStack(spacing: 0) {
                ProfilePhotoOptionRow(
                    title: Inc.Profile.takePhoto.localized,
                    systemImage: "camera",
                    role: nil,
                    action: onCamera
                )

                optionDivider

                ProfilePhotoOptionRow(
                    title: Inc.Profile.galleryPhoto.localized,
                    systemImage: "photo",
                    role: nil,
                    action: onGallery
                )

                if image != nil {
                    optionDivider

                    ProfilePhotoOptionRow(
                        title: Inc.Profile.deletePhoto.localized,
                        systemImage: "trash",
                        role: .destructive,
                        action: onDelete
                    )
                }
            }
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 20)
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill")
                .resizable()
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
        }
    }

    private var optionDivider: some View {
        Divider()
            .padding(.leading, 58)
    }
}

private struct ProfilePhotoOptionRow: View {
    let title: String
    let systemImage: String
    let role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 18) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .regular))
                    .frame(width: 22)

                Text(title)
                    .font(.system(size: 16))

                Spacer()
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 18)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .presentationBackground(.clear)
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

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = min(max(settledScale * value, 0.62), 5)

                if scale <= 1 {
                    offset = .zero
                    settledOffset = .zero
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

                settledScale = scale
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }

                offset = CGSize(
                    width: settledOffset.width + value.translation.width,
                    height: settledOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1 else { return }
                settledOffset = offset
            }
    }

    var body: some View {
        GeometryReader { proxy in
            content
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(scale)
                .offset(offset)
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
                        }
                    }
                }
        }
        .clipped()
    }
}
