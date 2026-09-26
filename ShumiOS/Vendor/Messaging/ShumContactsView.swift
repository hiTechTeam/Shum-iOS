#if os(iOS)
import BitFoundation
import Contacts
import ContactsUI
import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI
import Vision

extension ShumContactCard: Identifiable {}

typealias ShumContactResolving = (
    ShumContactLocator,
    @escaping (Result<ShumContactCard, Error>) -> Void
) -> Void
struct ShumContactsView: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: ShumRuntime
    var showOwnQR: (() -> Void)? = nil
    var select: (ShumPeer) -> Void
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .body) private var sheetHeight = 280
    @State private var showQR = false
    @State private var showScanner = false
    @State private var showPhoneBook = false
    @State private var invitation: ShumContactCard?
    @State private var share: ShumShareItem?
    private var service: ShumMessageStore? { runtime.permanent }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showScanner = true } label: { Label("Сканировать код".localized, systemImage: "qrcode.viewfinder") }
                    Button {
                        if let showOwnQR {
                            showOwnQR()
                        } else {
                            showQR = true
                        }
                    } label: {
                        Label("Мой QR-код".localized, systemImage: "qrcode")
                    }
                    Button { showPhoneBook = true } label: { Label("Пригласить".localized, systemImage: "person.badge.plus") }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDisabled(true)
            .navigationTitle("Новый контакт".localized).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Закрыть".localized)
                        .tint(.primary)
                }
            }
            .fullScreenCover(isPresented: $showQR) {
                if let card = service?.ownCard {
                    NavigationStack {
                        ShumQRView(
                            card: card,
                            resolve: { locator, completion in
                                runtime.resolveContact(locator, completion: completion)
                            }
                        ) { scannedCard in
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                                invitation = scannedCard
                            }
                        }
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                ShumScanView(resolve: { locator, completion in
                    runtime.resolveContact(locator, completion: completion)
                }) { card in
                    showScanner = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        invitation = card
                    }
                }
            }
            .sheet(isPresented: $showPhoneBook) {
                ShumPhoneBook { contact in
                    showPhoneBook = false
                    let name = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        let greeting = name.isEmpty ? "Привет!".localized : String.localizedFormat("%@, привет!".localized, name)
                        if let url = try? service?.ownCard.sharingInvitation() {
                            share = ShumShareItem(text: String.localizedFormat("%@ Добавь меня в Shum:\n%@".localized, greeting, url.absoluteString))
                        }
                    }
                }
            }
            .sheet(item: $share) { ShumShareSheet(items: [$0.text]) }
            .sheet(item: $invitation) { card in
                ShumContactConfirmation(
                    card: card,
                    imageData: runtime.profile(for: card.peerID)?.avatar,
                    isExistingContact: isExistingContact(card)
                ) {
                    open(card, source: "invitation")
                }
            }
        }
        .tint(palette.accent)
        .presentationDetents([.height(sheetHeight)])
        .presentationDragIndicator(.visible)
    }
    private func open(_ card: ShumContactCard, source: String) {
        let peer: ShumPeer
        if isExistingContact(card) {
            peer = ShumPeer(id: card.peerID, name: card.name, lastConnected: Date())
        } else {
            guard let added = runtime.addContact(card, source: source) else { return }
            peer = added
        }
        dismiss(); select(peer)
    }

    private func isExistingContact(_ card: ShumContactCard) -> Bool {
        runtime.permanent?.state.contacts.contains { $0.id == card.id } == true
    }
}
struct ShumContactRequestsView: View {
    @ObservedObject var runtime: ShumRuntime
    var select: (ShumPeer) -> Void
    @State private var invitation: ShumContactCard?

    var body: some View {
        List {
            ForEach(runtime.permanent?.state.requests ?? []) { card in
                Button { invitation = card } label: {
                    HStack(spacing: 12) {
                        ShumAvatar(name: card.name, size: 48, imageData: runtime.profile(for: card.peerID)?.avatar)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.name).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            Text("Хочет добавить вас".localized).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                    }
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button { runtime.permanent?.dismissRequest(card) } label: {
                        Label("Отклонить".localized, systemImage: "xmark")
                    }.tint(.red)
                }
            }
        }
        .navigationTitle("Приглашения".localized)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $invitation) { card in
            ShumContactConfirmation(
                card: card,
                imageData: runtime.profile(for: card.peerID)?.avatar
            ) {
                if let peer = runtime.addContact(card, source: "invitation") {
                    invitation = nil
                    select(peer)
                }
            }
        }
    }
}
struct ShumContactConfirmation: View {
    let card: ShumContactCard
    var imageData: Data? = nil
    var isExistingContact = false
    var accept: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showPhoto = false

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = min(360, max(0, geometry.size.width - 48))

            VStack(spacing: 0) {
                Spacer(minLength: 28)

                ShumAvatar(name: card.name, size: 202, imageData: imageData)
                    .contentShape(Circle())
                    .onTapGesture(perform: openPhoto)
                    .accessibilityLabel(imageData == nil ? card.name : "Посмотреть фото".localized)

                Text(card.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: contentWidth)
                    .padding(.top, 12)

                if !card.bio.isEmpty {
                    Text(card.bio)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(width: contentWidth)
                        .padding(.top, 4)
                }

                Text(isExistingContact ? "Уже есть в контактах".localized : "Сохранить контакт Shum?".localized)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, card.bio.isEmpty ? 6 : 4)

                Button(isExistingContact ? "Написать".localized : "Добавить контакт".localized) {
                    dismiss()
                    accept()
                }
                .buttonStyle(ShumPrimaryButtonStyle())
                .controlSize(.large)
                .frame(width: contentWidth)
                .padding(.top, 14)

                Button("Отмена".localized) { dismiss() }
                    .font(.system(size: 16))
                    .frame(minHeight: 36)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 8)
        }
        .fullScreenCover(isPresented: $showPhoto) {
            if let imageData, let image = UIImage(data: imageData) {
                FullScreenPhotoView(isPresented: $showPhoto) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func openPhoto() {
        guard imageData.flatMap(UIImage.init(data:)) != nil else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            showPhoto = true
        }
    }
}
struct ShumPhoneBook: UIViewControllerRepresentable {
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

#endif
