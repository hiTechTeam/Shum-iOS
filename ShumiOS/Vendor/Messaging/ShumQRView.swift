#if os(iOS)
import BitFoundation
import Contacts
import ContactsUI
import CoreImage.CIFilterBuiltins
import SwiftUI
import Vision

struct ShumQRView: View {
    let card: ShumContactCard
    var resolve: ShumContactResolving?
    var scanned: ((ShumContactCard) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false

    init(
        card: ShumContactCard,
        resolve: ShumContactResolving? = nil,
        scanned: ((ShumContactCard) -> Void)? = nil
    ) {
        self.card = card
        self.resolve = resolve
        self.scanned = scanned
    }

    private var invitationURL: URL? {
        try? card.compactQRInvitation()
    }

    private var avatarData: Data? {
        guard let manifest = LocalCardStore.shared.ownManifest else { return nil }
        if let seed = manifest.body.avatarSeed {
            return ShumPixelAvatarGenerator.data(seed: seed)
        }
        return LocalCardStore.shared.photo(manifest.body.photoHash)
    }

    var body: some View {
        ZStack {
            ShumThemeCanvas().ignoresSafeArea()

            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        if let invitationURL,
                           let image = qr(invitationURL.absoluteString) {
                            profileCard(qrImage: image)
                                .padding(.top, 54)

                            Text("Покажите QR-код человеку, чтобы он добавил вас в контакты Shum. Код содержит только открытый идентификатор.".localized)
                                .font(.system(size: 15, weight: .regular))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineSpacing(3)
                                .frame(maxWidth: 330)
                                .padding(.top, 22)
                                .padding(.horizontal, 24)
                        }

                        Spacer(minLength: 28)

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            showScanner = true
                        } label: {
                            Text("Сканировать".localized)
                        }
                        .buttonStyle(ShumPrimaryButtonStyle())
                        .frame(maxWidth: 342)
                        .padding(.horizontal, 30)
                        .padding(.bottom, 22)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: geometry.size.height)
                }
                .scrollIndicators(.hidden)
            }
        }
        .shumAllowsScreenshots()
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { gesture in
                    guard gesture.startLocation.x < 24,
                          gesture.translation.width > 80,
                          abs(gesture.translation.height) < 60 else { return }
                    dismiss()
                }
        )
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            navigationHeader
        }
        .fullScreenCover(isPresented: $showScanner) {
            ShumScanView(resolve: resolve) { scannedCard in
                showScanner = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        scanned?(scannedCard)
                    }
                }
            }
        }
    }

    // Keep the original flat, 44-point navigation row on every iOS version.
    // The system bar adds glass capsules and a taller row on iOS 26.
    private var navigationHeader: some View {
        GeometryReader { geometry in
            ZStack {
                Text("QR-код".localized)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

                HStack(spacing: 0) {
                    Button { dismiss() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .semibold))
                            Text(card.name)
                                .font(.system(size: 17))
                                .lineLimit(1)
                        }
                        .frame(height: 44)
                        .contentShape(Rectangle())
                    }
                    .frame(maxWidth: max(44, (geometry.size.width - 120) / 2), alignment: .leading)
                    .accessibilityLabel("Назад".localized)

                    Spacer(minLength: 0)

                    if let invitationURL = try? card.sharingInvitation() {
                        ShareLink(item: invitationURL) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 24, weight: .regular))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Поделиться контактом Shum".localized)
                    }
                }
                .padding(.horizontal, 8)
            }
            .foregroundStyle(.primary)
            .buttonStyle(.plain)
        }
        .frame(height: 44)
        .background(ShumThemeCanvas())
    }

    private func profileCard(qrImage: UIImage) -> some View {
        VStack(spacing: 0) {
            ShumAvatar(
                name: card.name,
                size: 62,
                imageData: avatarData
            )
            .overlay {
                Circle()
                    .stroke(Color(.secondarySystemBackground), lineWidth: 4)
            }

            Text(card.name)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 14)

            Text("Контакт Shum".localized)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            ZStack {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(20)

                Image.shumLogo
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)

                Image.shumLogo
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .foregroundStyle(.black)
                    .frame(width: 30, height: 30)
            }
            .frame(width: 252, height: 252)
            .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.top, 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("QR-код контакта Shum".localized)
        }
        .padding(.bottom, 30)
        .frame(maxWidth: 342)
        .background(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .padding(.top, 31)
        }
        .padding(.horizontal, 30)
    }

    private func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "H"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
struct ShumShareItem: Identifiable { let id = UUID(); let text: String }
struct ShumShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#endif
