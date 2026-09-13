#if os(iOS)
import BitFoundation
import Contacts
import ContactsUI
import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI
import Vision

extension SpotchatContactCard: Identifiable {}

struct SpotchatContactsView: View {
    @ObservedObject var runtime: SpotchatRuntime
    var select: (SpotchatPeer) -> Void
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var sheetHeight = 280
    @State private var showQR = false
    @State private var showScanner = false
    @State private var showPhoneBook = false
    @State private var invitation: SpotchatContactCard?
    @State private var share: SpotchatShareItem?
    private var service: SpotchatMessageStore? { runtime.permanent }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showScanner = true } label: { Label("Сканировать код", systemImage: "qrcode.viewfinder") }
                    Button { showQR = true } label: { Label("Мой QR-код", systemImage: "qrcode") }
                    Button { showPhoneBook = true } label: { Label("Пригласить", systemImage: "person.badge.plus") }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDisabled(true)
            .navigationTitle("Новый контакт").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Закрыть")
                        .tint(.primary)
                }
            }
            .fullScreenCover(isPresented: $showQR) { if let card = service?.ownCard { SpotchatQRView(card: card) } }
            .sheet(isPresented: $showScanner) { SpotchatScanView { card in showScanner = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { invitation = card } } }
            .sheet(isPresented: $showPhoneBook) {
                SpotchatPhoneBook { contact in
                    showPhoneBook = false
                    let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let greeting = name.isEmpty ? "Привет!" : "\(name), привет!"
                        if let url = try? service?.ownCard.invitation() {
                            share = SpotchatShareItem(text: "\(greeting) Добавь меня в Shum:\n\(url.absoluteString)")
                        }
                    }
                }
            }
            .sheet(item: $share) { SpotchatShareSheet(items: [$0.text]) }
            .sheet(item: $invitation) { card in SpotchatContactConfirmation(card: card) { open(card, source: "invitation") } }
        }
        .tint(.accentColor)
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
    }
    private func open(_ card: SpotchatContactCard, source: String) {
        guard let peer = runtime.addContact(card, source: source) else { return }
        dismiss(); select(peer)
    }
}

struct SpotchatContactRequestsView: View {
    @ObservedObject var runtime: SpotchatRuntime
    var select: (SpotchatPeer) -> Void
    @State private var invitation: SpotchatContactCard?

    var body: some View {
        List {
            ForEach(runtime.permanent?.state.requests ?? []) { card in
                Button { invitation = card } label: {
                    HStack(spacing: 12) {
                        SpotchatAvatar(name: card.name, size: 48, imageData: runtime.profile(for: card.peerID)?.avatar)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text("Хочет добавить вас").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button { runtime.permanent?.dismissRequest(card) } label: {
                        Label("Отклонить", systemImage: "xmark")
                    }.tint(.red)
                }
            }
        }
        .navigationTitle("Приглашения")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $invitation) { card in
            SpotchatContactConfirmation(card: card) {
                if let peer = runtime.addContact(card, source: "invitation") {
                    invitation = nil
                    select(peer)
                }
            }
        }
    }
}

struct SpotchatContactConfirmation: View {
    let card: SpotchatContactCard
    var accept: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 18) {
            SpotchatAvatar(name: card.name, size: 110)
            Text(card.name).font(.title2.bold())
            if !card.bio.isEmpty { Text(card.bio).font(.subheadline).multilineTextAlignment(.center) }
            Text("Сохранить контакт Shum?").foregroundStyle(.secondary)
            Button("Добавить контакт") { dismiss(); accept() }.buttonStyle(ShumPrimaryButtonStyle()).controlSize(.large)
            Button("Отмена") { dismiss() }
        }.padding(24).presentationDetents([.medium]).presentationDragIndicator(.visible)
    }
}
struct SpotchatQRView: View {
    let card: SpotchatContactCard
    @Environment(\.dismiss) private var dismiss

    private var invitationURL: URL? {
        try? card.invitation()
    }

    private var avatarData: Data? {
        guard let manifest = LocalCardStore.shared.ownManifest else { return nil }
        return LocalCardStore.shared.photo(manifest.body.photoHash)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemBackground).ignoresSafeArea()

                GeometryReader { geometry in
                    ScrollView {
                        VStack(spacing: 0) {
                            if let invitationURL,
                               let image = qr(invitationURL.absoluteString) {
                                profileCard(qrImage: image)
                                    .padding(.top, 54)

                                Text("Покажите QR-код человеку, чтобы он добавил вас в контакты Shum. Код содержит только открытые данные профиля.")
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineSpacing(3)
                                    .frame(maxWidth: 330)
                                    .padding(.top, 22)
                                    .padding(.horizontal, 24)
                            }

                            Spacer(minLength: 28)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: geometry.size.height)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .navigationTitle("QR-код")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        ShumQRToolbarIcon(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Назад")
                }

                if let invitationURL {
                    ToolbarItem(placement: .confirmationAction) {
                        ShareLink(item: invitationURL) {
                            ShumQRToolbarIcon(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Поделиться контактом Shum")
                    }
                }
            }
        }
    }

    private func profileCard(qrImage: UIImage) -> some View {
        VStack(spacing: 0) {
            SpotchatAvatar(
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

            Text("Контакт Shum")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.top, 5)

            ZStack {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(20)

                Circle()
                    .fill(.white)
                    .frame(width: 42, height: 42)

                Image.shumLogo
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 30, height: 30)
            }
            .frame(width: 252, height: 252)
            .background(.white, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(.top, 28)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("QR-код контакта Shum")
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
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "Q"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct ShumQRToolbarIcon: View {
    let systemName: String

    var body: some View {
        if #available(iOS 26.0, *) {
            icon
                .glassEffect(.regular, in: Circle())
        } else {
            icon
                .background(Color(.secondarySystemBackground), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                }
        }
    }

    private var icon: some View {
        Image(systemName: systemName)
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 44, height: 44)
    }
}
struct SpotchatScanView: View {
    var scanned: (SpotchatContactCard) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var done = false
    @State private var unavailable = false
    @State private var error: String?
    @State private var torchEnabled = false
    @State private var photoSelection: PhotosPickerItem?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if unavailable {
                    VStack(spacing: 16) {
                        Text("Разрешите доступ к камере в настройках iPhone.").multilineTextAlignment(.center)
                        Button("Открыть настройки") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    }.foregroundStyle(.white).padding()
                } else {
                    CameraScannerView(
                        isActive: !done,
                        torchEnabled: torchEnabled,
                        onUnavailable: { unavailable = true }
                    ) { text in
                        handle(text)
                    }

                    scannerOverlay
                }
            }.navigationTitle("Сканировать QR-код").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { done = true; dismiss() } } }
                .alert("QR-код", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil; done = false } })) { Button("Повторить") { error = nil; done = false } } message: { Text(error ?? "") }
                .task(id: photoSelection) {
                    guard let photoSelection else { return }
                    await scanPhoto(photoSelection)
                    self.photoSelection = nil
                }
                .onDisappear { done = true }
        }
    }

    private var scannerOverlay: some View {
        VStack(spacing: 0) {
            Spacer()

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white, lineWidth: 3)
                .frame(width: 264, height: 264)
                .shadow(color: .black.opacity(0.35), radius: 8)

            Text("Наведите камеру на QR-код Shum")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.top, 20)
                .shadow(color: .black, radius: 4)

            Spacer()

            HStack(spacing: 24) {
                Button {
                    torchEnabled.toggle()
                } label: {
                    Label(
                        torchEnabled ? "Выключить фонарик" : "Включить фонарик",
                        systemImage: torchEnabled ? "flashlight.on.fill" : "flashlight.off.fill"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.white)

                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Label("Выбрать из Фото", systemImage: "photo.on.rectangle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(.white)
            }
            .font(.title3)
            .padding(.bottom, 30)
        }
        .padding(.horizontal, 24)
    }

    private func handle(_ text: String) {
        guard !done else { return }
        done = true
        torchEnabled = false
        do {
            guard let url = URL(string: text) else { throw SpotchatFailure.invalidContact }
            scanned(try SpotchatContactCard.parse(url))
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func scanPhoto(_ item: PhotosPickerItem) async {
        done = true
        torchEnabled = false

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let cgImage = image.cgImage else {
                throw SpotchatFailure.invalidContact
            }

            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(cgImage: cgImage).perform([request])

            guard let text = request.results?.first?.payloadStringValue else {
                error = "На выбранной фотографии QR-код не найден."
                return
            }
            done = false
            handle(text)
        } catch {
            self.error = "Не получилось прочитать QR-код из выбранной фотографии."
        }
    }
}
struct SpotchatPhoneBook: UIViewControllerRepresentable {
    var selected: (CNContact) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        // The system picker grants access only to the chosen contact. No bulk
        // CNContactStore fetch, upload or phone-number-based identity is used.
        _ = CNContactStore.authorizationStatus(for: .contacts)
        let picker = CNContactPickerViewController(); picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}
    final class Coordinator: NSObject, CNContactPickerDelegate {
        let selected: (CNContact) -> Void
        init(selected: @escaping (CNContact) -> Void) { self.selected = selected }
        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) { selected(contact) }
    }
}
struct SpotchatShareItem: Identifiable { let id = UUID(); let text: String }
struct SpotchatShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
