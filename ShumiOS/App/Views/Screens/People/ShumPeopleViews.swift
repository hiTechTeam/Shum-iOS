import SwiftUI
import UIKit

struct ShumProfileBlockRequest: Identifiable {
    let id = UUID()
    let peer: ShumPeer
    let card: ShumContactCard
    let waitsForTransientUI: Bool
}

struct ShumPeopleScreen: View {
    @Environment(\.shumThemePalette) private var palette
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var runtime: ShumRuntime
    let select: (ShumPeer) -> Void

    @State private var selectedPeer: ShumPeer?
    @State private var blockRequest: ShumProfileBlockRequest?

    var body: some View {
        ZStack {
            ShumThemeCanvas().ignoresSafeArea()

            if !coordinator.isScaning {
                ShumPeopleUnavailable(
                    title: "Люди рядом скрыты".localized,
                    message: "Включите видимость, чтобы находить людей поблизости.".localized,
                    systemImage: "eye.slash",
                    actionTitle: "Найти людей".localized
                ) {
                    coordinator.setScanning(true)
                }
            } else if runtime.bluetoothState == .unauthorized {
                ShumPeopleUnavailable(
                    title: "Нужен Bluetooth".localized,
                    message: "Разрешите Bluetooth для Shum в настройках iPhone.".localized,
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    actionTitle: "Открыть настройки".localized
                ) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } else if runtime.bluetoothState == .poweredOff {
                ShumPeopleUnavailable(
                    title: "Bluetooth выключен".localized,
                    message: "Включите Bluetooth на iPhone, чтобы увидеть людей рядом.".localized,
                    systemImage: "antenna.radiowaves.left.and.right.slash"
                )
            } else if runtime.peers.isEmpty {
                ShumPeopleUnavailable(
                    title: "Никого рядом".localized,
                    message: "Откройте Shum на другом iPhone. Человек появится здесь, когда окажется поблизости.".localized,
                    systemImage: "wave.3.up"
                )
            } else {
                peopleList
            }
        }
        .navigationTitle("Люди рядом".localized)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPeer) { peer in
            ShumPeerCard(runtime: runtime, peer: peer) {
                selectedPeer = nil
                select(peer)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .shumProfileBlockSheet(runtime: runtime, request: $blockRequest)
    }

    private var peopleList: some View {
        List {
            Text("Здесь появляются пользователи Shum поблизости.".localized)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(runtime.peers) { peer in
                let card = runtime.permanent?.card(for: peer.id)
                let pinned = card.map {
                    runtime.permanent?.isPinned($0, in: ShumChatFolder.nearby.pinKey) == true
                } ?? false

                NativeSwipeInteractionRow {
                    ShumPeopleRow(
                        runtime: runtime,
                        peer: peer,
                        cardAction: { selectedPeer = peer },
                        writeAction: { select(peer) }
                    )
                    .shumPeopleContextMenu(
                        runtime: runtime,
                        peer: peer,
                        card: card,
                        writeAction: { select(peer) },
                        blockAction: {
                            requestBlock(
                                card,
                                peer: peer,
                                waitsForTransientUI: false
                            )
                        }
                    )
                    .background {
                        if pinned {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(palette.pinnedRowSurface)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                    }
                    .animation(.easeOut(duration: 0.22), value: pinned)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(ShumThemeCanvas())
                .listRowSeparator(.hidden)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if let card {
                        Button {
                            togglePinned(card)
                        } label: {
                            Label(pinned ? "Открепить".localized : "Закрепить".localized, systemImage: pinned ? "pin.slash" : "pin.fill")
                        }
                        .tint(pinned ? Color(uiColor: .systemGray) : .accentColor)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if let card {
                        Button {
                            requestBlock(
                                card,
                                peer: peer,
                                waitsForTransientUI: true
                            )
                        } label: {
                            Label("Заблокировать".localized, systemImage: "person.crop.circle.badge.xmark")
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { runtime.tick() }
    }

    private func togglePinned(_ card: ShumContactCard) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        do {
            _ = try runtime.permanent?.togglePinned(card, in: ShumChatFolder.nearby.pinKey)
        } catch { runtime.error = error.localizedDescription }
    }

    private func requestBlock(
        _ card: ShumContactCard?,
        peer: ShumPeer,
        waitsForTransientUI: Bool
    ) {
        guard let card else {
            runtime.error = "Дождитесь проверки профиля пользователя.".localized
            return
        }
        blockRequest = ShumProfileBlockRequest(
            peer: peer,
            card: card,
            waitsForTransientUI: waitsForTransientUI
        )
    }
}

private struct ShumPeopleUnavailable: View {
    let title: String
    let message: String
    let systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        title: String,
        message: String,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                RegistrationPrimaryButton(title: actionTitle, action: action)
                    .frame(maxWidth: 320)
                    .padding(.top, 8)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ShumPeopleRow: View {
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    let cardAction: () -> Void
    let writeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ShumRowPressButton(action: {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                cardAction()
            }) {
                HStack(spacing: 12) {
                    ShumProfileAvatar(
                        name: runtime.displayName(peer),
                        size: 52,
                        imageData: runtime.profile(for: peer.id)?.avatar
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(runtime.displayName(peer))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    ShumDistanceLabel(runtime: runtime, peer: peer)
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

}

struct ShumProfileAvatar: View {
    let name: String
    let size: CGFloat
    let imageData: Data?

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ShumInitialsAvatar(name: name, size: size)
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
        .clipShape(Circle())
    }
}

struct ShumCardAvatarLayout<Content: View>: View {
    let size: CGFloat
    let availableWidth: CGFloat
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            content(size)
        } else {
            // A sheet drag changes its proposed height. Keep the photo, mask and
            // initials at one layout size, and scale the composed avatar together.
            let referenceSize = max(1, availableWidth)
            content(referenceSize)
                .compositingGroup()
                .scaleEffect(size / referenceSize)
                .frame(width: size, height: size)
                .transaction { $0.animation = nil }
        }
    }
}

private struct ShumDistanceLabel: View {
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer

    var body: some View {
        Group {
            if let meters = runtime.distanceMeters(for: peer.id) {
                Text(String.localizedFormat("%@ м".localized, meters))
                    .accessibilityLabel(String.localizedFormat("Примерное расстояние: %@ метров".localized, meters))
            } else {
                Text(runtime.isNearby(peer.id) ? "Рядом".localized : "Не рядом".localized)
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .layoutPriority(1)
    }
}

struct ShumPeerCard: View {
    @Environment(\.shumCaptureProtectionEnabled) private var protectsCapture
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    let profileCard: ShumContactCard?
    var lastMetAt: Date?
    var verifiesIdentity: Bool
    let write: () -> Void

    @State private var showPhoto = false
    @State private var showVerification = false
    @State private var isOpeningChat = false

    init(
        runtime: ShumRuntime,
        peer: ShumPeer,
        card: ShumContactCard? = nil,
        lastMetAt: Date? = nil,
        verifiesIdentity: Bool = false,
        write: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.peer = peer
        self.profileCard = card
        self.lastMetAt = lastMetAt
        self.verifiesIdentity = verifiesIdentity
        self.write = write
    }

    private var card: ShumContactCard? { profileCard ?? runtime.permanent?.card(for: peer.id) }
    private var avatar: Data? { runtime.profile(for: peer.id)?.avatar }

    var body: some View {
        GeometryReader { geometry in
            let contentWidth = min(360, max(0, geometry.size.width - 32))

            ZStack(alignment: .top) {
                VStack(spacing: 8) {
                    Spacer(minLength: 0)

                    GeometryReader { photoGeometry in
                        let availableSize = max(0, min(photoGeometry.size.width, photoGeometry.size.height) - 24)
                        let photoSize = availableSize * 0.9 * 1.04

                        ShumCardAvatarLayout(size: photoSize, availableWidth: photoGeometry.size.width) { size in
                            ShumProfileAvatar(
                                name: card?.name ?? runtime.displayName(peer),
                                size: size,
                                imageData: avatar
                            )
                        }
                            .contentShape(Circle())
                            .onTapGesture(perform: openPhoto)
                            .accessibilityLabel("Посмотреть фото".localized)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .offset(y: -10)
                    }

                    VStack(spacing: 16) {
                        Text(runtime.displayName(peer))
                            .font(.title.bold())
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(width: contentWidth)
                            .offset(y: -10)

                        if verifiesIdentity {
                            if card != nil {
                                RegistrationPrimaryButton(
                                    title: "Сверить ключ".localized,
                                    trailingSystemImage: "checkmark.shield",
                                    action: { showVerification = true }
                                )
                                .frame(width: contentWidth)
                            } else {
                                Text("Ключ контакта пока недоступен".localized)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(width: contentWidth)
                            }
                        } else {
                            RegistrationPrimaryButton(title: "Написать".localized) {
                                guard !isOpeningChat else { return }
                                isOpeningChat = true
                                write()
                            }
                                .frame(width: contentWidth)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .shumGeometryGroup()
                    .compositingGroup()
                }
                .padding(.top, 60)
                .offset(y: -10)
                .ignoresSafeArea(.keyboard, edges: .bottom)

                presenceInfo
                    .frame(width: contentWidth, height: 44, alignment: .leading)
                .padding(.top, 8)
            }
        }
        .shumProtectFromCapture(protectsCapture)
        .fullScreenCover(isPresented: $showPhoto) {
            if let avatar, let image = UIImage(data: avatar) {
                FullScreenPhotoView(isPresented: $showPhoto) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                .shumProtectFromCapture(protectsCapture)
            }
        }
        .sheet(isPresented: $showVerification) {
            if let card {
                ShumKeyVerificationView(
                    runtime: runtime,
                    peerCard: card
                )
            }
        }
    }

    private var presenceInfo: some View {
        Group {
            if let lastMetAt, !runtime.isNearby(peer.id) {
                Text(String.localizedFormat("Виделись %@".localized, lastMetAt.shumRelativeDescription))
            } else {
                HStack(spacing: 8) {
                    Text(runtime.isNearby(peer.id) ? "Рядом".localized : "Не рядом".localized)
                    if let meters = runtime.distanceMeters(for: peer.id) {
                        Text(String.localizedFormat("%@ м".localized, meters))
                            .accessibilityLabel(String.localizedFormat("Примерное расстояние: %@ метров".localized, meters))
                    }
                }
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.gray)
        .lineLimit(1)
    }

    private func openPhoto() {
        guard avatar != nil else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { showPhoto = true }
    }

}

private struct ShumPersonContextMenuModifier: ViewModifier {
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    let card: ShumContactCard?
    var lastMetAt: Date?
    var deleteAction: (() -> Void)?
    let writeAction: () -> Void
    let blockAction: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.contextMenu { menu } preview: {
                ShumPersonContextPreview(
                    runtime: runtime,
                    peer: peer,
                    lastMetAt: lastMetAt
                )
            }
        } else {
            content.contextMenu { menu }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(action: writeAction) {
            Label("Написать".localized, systemImage: "paperplane")
                .foregroundStyle(.primary)
        }
        .tint(.primary)

        if let deleteAction {
            Divider()
            Button(action: deleteAction) {
                Label("Удалить".localized, systemImage: "trash")
                    .foregroundStyle(.primary)
            }
            .tint(.primary)
        }

        Divider()

        Button(role: .destructive, action: blockAction) {
            Label("Заблокировать".localized, systemImage: "person.crop.circle.badge.xmark")
                .foregroundStyle(.red)
        }
        .tint(.red)
    }
}

private extension View {
    func shumPeopleContextMenu(
        runtime: ShumRuntime,
        peer: ShumPeer,
        card: ShumContactCard?,
        lastMetAt: Date? = nil,
        deleteAction: (() -> Void)? = nil,
        writeAction: @escaping () -> Void,
        blockAction: @escaping () -> Void
    ) -> some View {
        modifier(
            ShumPersonContextMenuModifier(
                runtime: runtime,
                peer: peer,
                card: card,
                lastMetAt: lastMetAt,
                deleteAction: deleteAction,
                writeAction: writeAction,
                blockAction: blockAction
            )
        )
    }
}

private struct ShumPersonContextPreview: View {
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    let lastMetAt: Date?

    private var sourceWidth: CGFloat { UIScreen.main.bounds.width }
    private var previewWidth: CGFloat { min(sourceWidth, max(320, sourceWidth - 32)) }
    private var previewScale: CGFloat { sourceWidth > 0 ? previewWidth / sourceWidth : 1 }

    var body: some View {
        HStack(spacing: 12) {
            ShumProfileAvatar(
                name: runtime.displayName(peer),
                size: 52,
                imageData: runtime.profile(for: peer.id)?.avatar
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(runtime.displayName(peer)).font(.system(size: 15, weight: .medium)).lineLimit(1)
            }

            Spacer(minLength: 8)

            if let lastMetAt {
                Text(lastMetAt.shumRelativeDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                ShumDistanceLabel(runtime: runtime, peer: peer)
            }

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: sourceWidth, height: 72)
        .background(
            Color(uiColor: .tertiarySystemBackground),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .scaleEffect(previewScale)
        .frame(width: previewWidth, height: 72 * previewScale)
    }

}

extension Date {
    fileprivate var shumRelativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

struct ShumEncounterHistoryView: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var runtime: ShumRuntime
    let openChat: (ShumPeer) -> Void

    @State private var selectedEncounter: ShumEncounter?
    @State private var pendingDelete: ShumEncounter?
    @State private var blockRequest: ShumProfileBlockRequest?
    @State private var showsClearConfirmation = false
    @State private var highlightedEncounterIDs: Set<String> = []
    @State private var elevatedEncounterIDs: Set<String> = []
    @State private var pinTransitionEncounterIDs: Set<String> = []

    private var encounters: [ShumEncounter] {
        let values = runtime.permanent?.encounterHistory ?? []
        let pinnedIDs = runtime.permanent?.pinnedCardIDs(
            in: ShumChatFolder.encounters.pinKey
        ) ?? []
        let pinnedRanks = Dictionary(
            uniqueKeysWithValues: pinnedIDs.enumerated().map { ($1, $0) }
        )
        return values.enumerated().sorted { lhs, rhs in
            let lhsRank = pinnedRanks[lhs.element.card.id]
            let rhsRank = pinnedRanks[rhs.element.card.id]
            switch (lhsRank, rhsRank) {
            case let (.some(left), .some(right)):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    var body: some View {
        ZStack {
            ShumThemeCanvas().ignoresSafeArea()

            if encounters.isEmpty {
                ShumEncounterHistoryEmptyState()
            } else {
                encounterList
            }
        }
        .navigationTitle("Виделись".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsClearConfirmation = true } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(
                            encounters.isEmpty
                                ? Color(uiColor: .systemGray2)
                                : Color.primary
                        )
                }
                .disabled(encounters.isEmpty)
                .accessibilityLabel("Очистить историю".localized)
            }
        }
        .sheet(item: $selectedEncounter) { encounter in
            let peer = encounter.peer
            ShumPeerCard(
                runtime: runtime,
                peer: peer,
                card: encounter.card,
                lastMetAt: encounter.lastSeen
            ) {
                selectedEncounter = nil
                openChat(peer)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert(
            "Удалить из «Виделись»?".localized,
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) {
            encounter in
            Button("Отмена".localized, role: .cancel) { pendingDelete = nil }
            Button("Очистить".localized, role: .destructive) {
                runtime.permanent?.deleteEncounter(encounter.card)
                pendingDelete = nil
            }
        } message: {
            _ in
            Text("Карточка будет удалена из списка «Виделись».".localized)
        }
        .alert("Очистить историю встреч?".localized, isPresented: $showsClearConfirmation) {
            Button("Отмена".localized, role: .cancel) { }
            Button("Очистить историю".localized, role: .destructive) {
                runtime.permanent?.clearEncounters()
            }
        } message: {
            Text("Все сохранённые на этом устройстве встречи будут удалены.".localized)
        }
        .shumProfileBlockSheet(runtime: runtime, request: $blockRequest)
    }

    private var encounterList: some View {
        List {
            Text("История хранится только на этом устройстве в зашифрованном виде.".localized)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(encounters) { encounter in
                let peer = encounter.peer
                let pinned = isPinned(encounter)

                NativeSwipeInteractionRow(
                    persistentSurfaceColor: highlightedEncounterIDs.contains(encounter.id)
                        ? Color.orange.opacity(0.16)
                        : pinned
                            ? palette.pinnedRowSurface
                            : nil,
                    hidesPersistentSurfaceAfterSwipe: !pinned
                ) {
                    ShumStoredPersonRow(
                        runtime: runtime,
                        peer: peer,
                        lastMetAt: encounter.lastSeen,
                        cardAction: { selectedEncounter = encounter },
                        writeAction: { openChat(peer) }
                    )
                    .contextMenu {
                        Button { selectedEncounter = encounter } label: {
                            Label("Посмотреть профиль".localized, systemImage: "person.crop.circle")
                                .foregroundStyle(.primary)
                        }
                        .tint(.primary)
                        Button { openChat(peer) } label: {
                            Label("Написать".localized, systemImage: "paperplane")
                                .foregroundStyle(.primary)
                        }
                        .tint(.primary)
                        Button { togglePinned(encounter) } label: {
                            Label(pinned ? "Открепить".localized : "Закрепить".localized, systemImage: pinned ? "pin.slash" : "pin.fill")
                                .foregroundStyle(.primary)
                        }
                        .tint(.primary)
                        Button(role: .destructive) { pendingDelete = encounter } label: {
                            Label("Очистить".localized, systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .tint(.red)
                        Divider()
                        Button(role: .destructive) {
                            blockRequest = ShumProfileBlockRequest(
                                peer: peer,
                                card: encounter.card,
                                waitsForTransientUI: false
                            )
                        } label: {
                            Label("Заблокировать".localized, systemImage: "person.crop.circle.badge.xmark")
                                .foregroundStyle(.red)
                        }
                        .tint(.red)
                    } preview: {
                        ShumEncounterContextPreview(
                            runtime: runtime,
                            peer: peer,
                            lastMetAt: encounter.lastSeen
                        )
                    }
                }
                .onAppear {
                    revealEncounterIfNeeded(encounter)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(ShumThemeCanvas())
                .listRowSeparator(.hidden)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 80 }
                .zIndex(elevatedEncounterIDs.contains(encounter.id) ? 1_000 : (pinned ? 1 : 0))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { togglePinned(encounter) } label: {
                        Label(pinned ? "Открепить".localized : "Закрепить".localized, systemImage: pinned ? "pin.slash" : "pin.fill")
                    }
                    .tint(pinned ? Color(uiColor: .systemGray) : .accentColor)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button { pendingDelete = encounter } label: {
                        Label("Очистить".localized, systemImage: "trash")
                    }
                    .tint(Color(uiColor: .systemGray))

                    Button {
                        blockRequest = ShumProfileBlockRequest(
                            peer: peer,
                            card: encounter.card,
                            waitsForTransientUI: true
                        )
                    } label: {
                        Label("Заблокировать".localized, systemImage: "person.crop.circle.badge.xmark")
                    }
                    .tint(.red)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(
            .spring(response: 0.48, dampingFraction: 0.84),
            value: encounters.map(\.id)
        )
    }

    private func isPinned(_ encounter: ShumEncounter) -> Bool {
        runtime.permanent?.isPinned(encounter.card, in: ShumChatFolder.encounters.pinKey) == true
    }

    private func togglePinned(_ encounter: ShumEncounter) {
        guard pinTransitionEncounterIDs.insert(encounter.id).inserted else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let encounterID = encounter.id
        Task { @MainActor in
            // First return the native swipe/context menu to its resting position.
            try? await Task.sleep(for: .milliseconds(300))
            elevatedEncounterIDs.insert(encounterID)

            // Apply zIndex before the data reorder so the moving row stays on top.
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(35))

            do {
                try withAnimation(.spring(response: 0.52, dampingFraction: 0.86)) {
                    _ = try runtime.permanent?.togglePinned(
                        encounter.card,
                        in: ShumChatFolder.encounters.pinKey
                    )
                }
            } catch {
                runtime.error = error.localizedDescription
            }

            try? await Task.sleep(for: .milliseconds(650))
            elevatedEncounterIDs.remove(encounterID)
            pinTransitionEncounterIDs.remove(encounterID)
        }
    }

    private func revealEncounterIfNeeded(_ encounter: ShumEncounter) {
        guard runtime.permanent?.unviewedEncounterIDs.contains(encounter.id) == true,
              highlightedEncounterIDs.insert(encounter.id).inserted else {
            return
        }

        runtime.permanent?.markEncounterViewed(encounter.id)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(.easeOut(duration: 0.8)) {
                _ = highlightedEncounterIDs.remove(encounter.id)
            }
        }
    }
}

private struct ShumEncounterHistoryEmptyState: View {
    var body: some View {
        VStack(spacing: 0) {
            ShumPixelEmptyIcon(kind: .encounters)
                .foregroundStyle(.primary)
                .frame(width: 88, height: 68)
                .accessibilityHidden(true)

            Text("Пока не встречались".localized)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 26)

            Text("Встречи поблизости сохранятся здесь.".localized)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            Text("Все встречи за 24 часа".localized)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.top, 18)
        }
        .frame(maxWidth: 330)
        .padding(.horizontal, 24)
        .accessibilityElement(children: .contain)
    }
}

/// Matches the lifted chat-row geometry so holding an encounter does not use
/// the full-width rectangular List snapshot supplied by the system.
private struct ShumEncounterContextPreview: View {
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    let lastMetAt: Date

    private let sourceHeight: CGFloat = 72
    private var sourceWidth: CGFloat { UIScreen.main.bounds.width }
    private var previewWidth: CGFloat {
        min(sourceWidth, max(280, sourceWidth - 32))
    }
    private var previewScale: CGFloat {
        sourceWidth > 0 ? previewWidth / sourceWidth : 1
    }

    var body: some View {
        previewRow
            .frame(width: sourceWidth, height: sourceHeight)
            .clipShape(Capsule(style: .continuous))
            .containerShape(Capsule(style: .continuous))
            .scaleEffect(previewScale)
            .frame(
                width: previewWidth,
                height: sourceHeight * previewScale
            )
    }

    private var previewRow: some View {
        row
    }

    private var row: some View {
        ShumStoredPersonRow(
            runtime: runtime,
            peer: peer,
            lastMetAt: lastMetAt,
            cardAction: { },
            writeAction: { }
        )
        .allowsHitTesting(false)
    }
}

private struct ShumProfileBlockSheetModifier: ViewModifier {
    @Environment(\.shumCaptureProtectionEnabled) private var protectsCapture
    @ObservedObject var runtime: ShumRuntime
    @Binding var request: ShumProfileBlockRequest?
    @State private var activeRequest: ShumProfileBlockRequest?

    func body(content: Content) -> some View {
        content
            .sheet(item: $activeRequest) { pending in
                ShumProfileBlockOptionsSheet(
                    runtime: runtime,
                    request: pending,
                    onClose: { activeRequest = nil },
                    onBlock: { block(pending) }
                )
                .shumProtectFromCapture(protectsCapture)
                .presentationDetents([.height(195)])
                .presentationDragIndicator(.hidden)
            }
            .task(id: request?.id) {
                guard let pending = request else { return }
                if pending.waitsForTransientUI {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                guard !Task.isCancelled, request?.id == pending.id else { return }
                activeRequest = pending
            }
            .onChange(of: activeRequest?.id) { id in
                if id == nil { request = nil }
            }
    }

    private func block(_ pending: ShumProfileBlockRequest) {
        do {
            try runtime.permanent?.setBlocked(pending.card, blocked: true)
            activeRequest = nil
        } catch {
            runtime.error = error.localizedDescription
        }
    }
}

private struct ShumProfileBlockOptionsSheet: View {
    @ObservedObject var runtime: ShumRuntime
    let request: ShumProfileBlockRequest
    let onClose: () -> Void
    let onBlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                ShumProfileAvatar(
                    name: runtime.displayName(request.peer),
                    size: 44,
                    imageData: runtime.profile(for: request.peer.id)?.avatar
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Заблокировать пользователя?".localized)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(runtime.displayName(request.peer))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

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
                .accessibilityLabel("Закрыть".localized)
            }

            VStack(spacing: 0) {
                Button(role: .destructive, action: onBlock) {
                    HStack(spacing: 18) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 20, weight: .regular))
                            .frame(width: 22)

                        Text("Заблокировать".localized)
                            .font(.system(size: 16))

                        Spacer()
                    }
                    .foregroundStyle(Color.red)
                    .padding(.horizontal, 18)
                    .frame(height: 54)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
}

extension View {
    func shumProfileBlockSheet(
        runtime: ShumRuntime,
        request: Binding<ShumProfileBlockRequest?>
    ) -> some View {
        modifier(
            ShumProfileBlockSheetModifier(
                runtime: runtime,
                request: request
            )
        )
    }
}

private struct ShumStoredPersonRow: View {
    @ObservedObject var runtime: ShumRuntime
    let peer: ShumPeer
    var lastMetAt: Date?
    let cardAction: () -> Void
    let writeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ShumRowPressButton(action: {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                cardAction()
            }) {
                HStack(spacing: 12) {
                    ShumProfileAvatar(
                        name: runtime.displayName(peer),
                        size: 52,
                        imageData: runtime.profile(for: peer.id)?.avatar
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(runtime.displayName(peer))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if let lastMetAt {
                        Text(lastMetAt.shumRelativeDescription)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        ShumDistanceLabel(runtime: runtime, peer: peer)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

}

private extension ShumEncounter {
    var peer: ShumPeer {
        ShumPeer(id: card.peerID, name: card.name, lastConnected: lastSeen)
    }
}
