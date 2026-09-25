#if os(iOS)
import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI

struct ShumPeerProfileSheet: View {
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShumPeerCard(
            runtime: runtime,
            peer: peer,
            verifiesIdentity: true
        ) {}
            .environment(\.shumCaptureProtectionEnabled, true)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
    }
}

struct ShumKeyVerificationView: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: ShumRuntime
    let peerCard: ShumContactCard

    @Environment(\.dismiss) private var dismiss
    @State private var showScanner = false
    @State private var matches: Bool?

    private var ownCard: ShumContactCard? { runtime.permanent?.ownCard }
    private var invitationURL: URL? { try? ownCard?.invitation() }
    private var ownAvatar: Data? {
        guard let manifest = LocalCardStore.shared.ownManifest else { return nil }
        return LocalCardStore.shared.photo(manifest.body.photoHash)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    if let ownCard {
                        ShumAvatar(name: ownCard.name, size: 72, imageData: ownAvatar)

                        Text(ownCard.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.top, 14)
                    }

                    if let invitationURL,
                       let image = qr(invitationURL.absoluteString) {
                        ZStack {
                            Image(uiImage: image)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(18)

                            Image.shumLogo
                                .renderingMode(.template)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)

                            Image.shumLogo
                                .renderingMode(.template)
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .foregroundStyle(.black)
                                .frame(width: 28, height: 28)
                        }
                        .frame(width: 224, height: 224)
                        .background(.white, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                        .padding(.top, 24)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Ваш QR-код для сверки ключа".localized)
                    }

                    VStack(spacing: 9) {
                        Text("Ваш отпечаток ключа".localized)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(formattedOwnFingerprint)
                            .font(.system(.footnote, design: .monospaced).weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 22)

                    Text("Покажите этот QR-код собеседнику. Затем отсканируйте его код, чтобы подтвердить сохранённый ключ контакта.".localized)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .padding(.horizontal, 28)
                        .padding(.top, 20)

                    if let matches {
                        Label(
                            matches ? "Ключ собеседника совпадает".localized : "Ключ собеседника не совпадает".localized,
                            systemImage: matches ? "checkmark.shield.fill" : "xmark.shield.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(matches ? palette.accent : Color(uiColor: .systemGray))
                        .padding(.top, 20)
                    }

                    Button {
                        matches = nil
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        showScanner = true
                    } label: {
                        Text("Сканировать код собеседника".localized)
                    }
                    .buttonStyle(ShumPrimaryButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
            }
            .background(ShumThemeCanvas().ignoresSafeArea())
            .navigationTitle("Сверить ключ".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово".localized) { dismiss() }
                }
            }
        }
        .fullScreenCover(isPresented: $showScanner) {
            ShumScanView(
                resolve: { locator, completion in
                    runtime.resolveContact(locator, completion: completion)
                },
                allowsPhotoImport: false
            ) { scannedCard in
                showScanner = false
                verify(scannedCard)
            }
        }
        .shumProtectFromCapture()
    }

    private var formattedOwnFingerprint: String {
        let characters = Array((ownCard?.id ?? "").uppercased())
        let groups = stride(from: 0, to: characters.count, by: 4).map { start in
            String(characters[start ..< min(start + 4, characters.count)])
        }
        return stride(from: 0, to: groups.count, by: 4).map { start in
            groups[start ..< min(start + 4, groups.count)].joined(separator: " ")
        }.joined(separator: "\n")
    }

    private func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage?.transformed(
            by: CGAffineTransform(scaleX: 6, y: 6)
        ), let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private func verify(_ scannedCard: ShumContactCard) {
        let result = scannedCard.id == peerCard.id
            && scannedCard.signingKey == peerCard.signingKey
            && scannedCard.nostrKey == peerCard.nostrKey
        matches = result
        UINotificationFeedbackGenerator().notificationOccurred(
            result ? .success : .error
        )
    }
}

struct ShumPhotoViewer: View {
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
                    .accessibilityLabel("Фото профиля".localized)
            }
        }.overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.ultraThinMaterial, in: Circle())
            }.padding().accessibilityLabel("Закрыть фото".localized)
        }
    }
}
#endif
