#if os(iOS)
import BitFoundation
import Contacts
import ContactsUI
import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI
import Vision

struct ShumScanView: View {
    var resolve: ShumContactResolving?
    var allowsPhotoImport: Bool
    var scanned: (ShumContactCard) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.shumThemePalette) private var palette
    @State private var done = false
    @State private var unavailable = false
    @State private var error: String?
    @State private var torchEnabled = false
    @State private var photoSelection: PhotosPickerItem?
    @State private var selectedPhoto: UIImage?
    @State private var photoScale: CGFloat = 1
    @State private var photoOffset: CGSize = .zero
    @GestureState private var photoGestureScale: CGFloat = 1
    @GestureState private var photoGestureOffset: CGSize = .zero
    @State private var scanningPhoto = false
    @State private var resolving = false

    init(
        resolve: ShumContactResolving? = nil,
        allowsPhotoImport: Bool = true,
        scanned: @escaping (ShumContactCard) -> Void
    ) {
        self.resolve = resolve
        self.allowsPhotoImport = allowsPhotoImport
        self.scanned = scanned
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            #if targetEnvironment(simulator)
            LinearGradient(
                colors: [Color(white: 0.22), Color(white: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            #else
            if unavailable {
                VStack(spacing: 16) {
                    Text("Разрешите доступ к камере в настройках устройства.".localized)
                        .multilineTextAlignment(.center)
                    Button("Открыть настройки".localized) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .foregroundStyle(.white)
                .padding(32)
            } else {
                CameraScannerView(
                    isActive: !done && selectedPhoto == nil,
                    torchEnabled: torchEnabled,
                    onUnavailable: { unavailable = true }
                ) { text in
                    handle(text)
                }
                .ignoresSafeArea()
            }
            #endif

            scannerOverlay
                .ignoresSafeArea()

            if resolving {
                Color.black.opacity(0.52).ignoresSafeArea()
                VStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                    Text("Получаем контакт…".localized)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            VStack {
                HStack {
                    Button {
                        done = true
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 26, weight: .regular))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Закрыть".localized)

                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)

                Spacer()
            }
        }
        .statusBarHidden(true)
        .toolbar(.hidden, for: .tabBar)
        .alert("QR-код".localized, isPresented: Binding(
            get: { error != nil },
            set: {
                if !$0 {
                    error = nil
                    if selectedPhoto == nil { done = false }
                }
            }
        )) {
            Button("Повторить".localized) {
                error = nil
                if selectedPhoto == nil { done = false }
            }
        } message: {
            Text(error ?? "")
        }
        .task(id: photoSelection) {
            guard let photoSelection else { return }
            await loadPhoto(photoSelection)
            self.photoSelection = nil
        }
        .onDisappear { done = true }
    }

    private var scannerOverlay: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width - 96, 264)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let scanRect = CGRect(
                x: center.x - side / 2,
                y: center.y - side / 2,
                width: side,
                height: side
            )

            ZStack {
                if let selectedPhoto {
                    Image(uiImage: selectedPhoto)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(effectivePhotoScale)
                        .offset(effectivePhotoOffset)
                        .contentShape(Rectangle())
                        .gesture(photoDragGesture)
                        .simultaneousGesture(photoMagnificationGesture)
                        .onTapGesture(count: 2, perform: resetPhotoPosition)
                        .clipped()
                }

                ShumScannerShade(cutout: scanRect)
                    .fill(.black.opacity(0.52), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)

                ShumScannerCorners()
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: side, height: side)
                    .position(center)
                    .allowsHitTesting(false)

                Text(selectedPhoto == nil
                     ? "Наведите камеру на QR-код Shum".localized
                     : "Переместите и масштабируйте фото".localized)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 4)
                    .position(x: center.x, y: scanRect.maxY + 34)
                    .allowsHitTesting(false)

                VStack {
                    Spacer()

                    Group {
                        if let selectedPhoto {
                            HStack(spacing: 12) {
                                Button(action: clearSelectedPhoto) {
                                    scannerControlIcon("camera")
                                }

                                if allowsPhotoImport {
                                    PhotosPicker(selection: $photoSelection, matching: .images) {
                                        scannerControlIcon("photo.on.rectangle")
                                    }
                                }

                                Button {
                                    scanDisplayedPhoto(
                                        selectedPhoto,
                                        viewportSize: geometry.size,
                                        scanRect: scanRect
                                    )
                                } label: {
                                    ZStack {
                                        Text("Сканировать".localized)
                                            .opacity(scanningPhoto ? 0 : 1)
                                        if scanningPhoto {
                                            ProgressView().tint(palette.accentForeground)
                                        }
                                    }
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(palette.accentForeground)
                                    .frame(width: 144, height: 50)
                                    .background(palette.accent, in: Capsule())
                                    .contentShape(Capsule())
                                }
                                .disabled(scanningPhoto)
                            }
                            .buttonStyle(.plain)
                            .transaction { $0.animation = nil }
                        } else {
                            HStack(spacing: 24) {
                                Button {
                                    torchEnabled.toggle()
                                } label: {
                                    Label(
                                        torchEnabled ? "Выключить фонарик".localized : "Включить фонарик".localized,
                                        systemImage: torchEnabled ? "flashlight.on.fill" : "flashlight.off.fill"
                                    )
                                    .labelStyle(.iconOnly)
                                }
                                .buttonStyle(.bordered)
                                .buttonBorderShape(.capsule)
                                .controlSize(.large)
                                .tint(.white)

                                if allowsPhotoImport {
                                    PhotosPicker(selection: $photoSelection, matching: .images) {
                                        Label("Выбрать из Фото".localized, systemImage: "photo.on.rectangle")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.bordered)
                                    .buttonBorderShape(.capsule)
                                    .controlSize(.large)
                                    .tint(.white)
                                }
                            }
                        }
                    }
                    .font(.title3)
                    .padding(.bottom, 30)
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard !done else { return }
        done = true
        torchEnabled = false
        do {
            guard let url = URL(string: text) else { throw ShumFailure.invalidContact }
            switch try ShumInvitationPayload.parse(url) {
            case .card(let card):
                scanned(card)
            case .locator(let locator):
                guard let resolve else { throw ShumFailure.contactUnavailable }
                resolving = true
                resolve(locator) { result in
                    resolving = false
                    switch result {
                    case .success(let card): scanned(card)
                    case .failure(let error):
                        self.error = error.localizedDescription
                        done = false
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
            done = false
        }
    }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        done = true
        torchEnabled = false

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                throw ShumFailure.invalidContact
            }
            selectedPhoto = image
            resetPhotoPosition()
        } catch {
            self.error = "Не получилось открыть выбранную фотографию.".localized
        }
    }

    private var effectivePhotoScale: CGFloat {
        min(max(photoScale * photoGestureScale, 1), 8)
    }

    private var effectivePhotoOffset: CGSize {
        CGSize(
            width: photoOffset.width + photoGestureOffset.width,
            height: photoOffset.height + photoGestureOffset.height
        )
    }

    private var photoDragGesture: some Gesture {
        DragGesture()
            .updating($photoGestureOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                photoOffset.width += value.translation.width
                photoOffset.height += value.translation.height
            }
    }

    private var photoMagnificationGesture: some Gesture {
        MagnificationGesture()
            .updating($photoGestureScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                photoScale = min(max(photoScale * value, 1), 8)
            }
    }

    private func resetPhotoPosition() {
        photoScale = 1
        photoOffset = .zero
    }

    private func clearSelectedPhoto() {
        selectedPhoto = nil
        scanningPhoto = false
        resetPhotoPosition()
        done = false
    }

    private func scanDisplayedPhoto(
        _ photo: UIImage,
        viewportSize: CGSize,
        scanRect: CGRect
    ) {
        guard !scanningPhoto,
              let originalImage = ShumScannerPhotoRenderer.normalizedCGImage(photo),
              let rendered = ShumScannerPhotoRenderer.render(
                photo,
                viewportSize: viewportSize,
                scanRect: scanRect,
                zoom: effectivePhotoScale,
                offset: effectivePhotoOffset
              ),
              let cgImage = rendered.cgImage else {
            error = "Не получилось подготовить выбранную фотографию.".localized
            return
        }

        scanningPhoto = true
        Task { @MainActor in
            defer { scanningPhoto = false }
            await Task.yield()
            guard let text = ShumQRCodeDetector.payload(in: originalImage)
                    ?? ShumQRCodeDetector.payload(in: cgImage) else {
                error = "В рамке QR-код не найден. Переместите или увеличьте фото.".localized
                return
            }
            done = false
            handle(text)
        }
    }

    private func scannerControlIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 50, height: 50)
            .background(.ultraThinMaterial, in: Circle())
            .overlay {
                Circle().stroke(.white.opacity(0.35), lineWidth: 0.5)
            }
            .contentShape(Circle())
    }
}
enum ShumScannerPhotoRenderer {
    static func normalizedCGImage(_ image: UIImage) -> CGImage? {
        guard image.size.width > 0, image.size.height > 0 else { return nil }
        if image.imageOrientation == .up, let cgImage = image.cgImage { return cgImage }

        let format = UIGraphicsImageRendererFormat()
        format.scale = max(image.scale, 1)
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format)
            .image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: image.size))
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
            .cgImage
    }

    static func render(
        _ image: UIImage,
        viewportSize: CGSize,
        scanRect: CGRect,
        zoom: CGFloat,
        offset: CGSize,
        outputScale: CGFloat = 3
    ) -> UIImage? {
        guard image.size.width > 0, image.size.height > 0,
              viewportSize.width > 0, viewportSize.height > 0,
              scanRect.width > 0, scanRect.height > 0 else { return nil }

        let aspectFillScale = max(
            viewportSize.width / image.size.width,
            viewportSize.height / image.size.height
        )
        let displayScale = aspectFillScale * min(max(zoom, 1), 8)
        let displaySize = CGSize(
            width: image.size.width * displayScale,
            height: image.size.height * displayScale
        )
        let displayOrigin = CGPoint(
            x: (viewportSize.width - displaySize.width) / 2 + offset.width,
            y: (viewportSize.height - displaySize.height) / 2 + offset.height
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = outputScale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: scanRect.size, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: scanRect.size))
            image.draw(in: CGRect(
                x: displayOrigin.x - scanRect.minX,
                y: displayOrigin.y - scanRect.minY,
                width: displaySize.width,
                height: displaySize.height
            ))
        }
    }
}
enum ShumQRCodeDetector {
    static func payload(in image: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        if (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
           let value = request.results?.first?.payloadStringValue {
            return value
        }

        // Core Image provides a second decoding path for photographs on which
        // Vision cannot create an inference context or returns no observation.
        let options = [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        guard let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: CIContext(),
            options: options
        ) else { return nil }
        return detector.features(in: CIImage(cgImage: image))
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            .first
    }
}
private struct ShumScannerShade: Shape {
    let cutout: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(
            in: cutout,
            cornerSize: CGSize(
                width: ShumScannerGeometry.cornerRadius,
                height: ShumScannerGeometry.cornerRadius
            )
        )
        return path
    }
}
private struct ShumScannerCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length: CGFloat = 38
        let radius = ShumScannerGeometry.cornerRadius
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        return path
    }
}
private enum ShumScannerGeometry {
    static let cornerRadius: CGFloat = 22
}

#endif
