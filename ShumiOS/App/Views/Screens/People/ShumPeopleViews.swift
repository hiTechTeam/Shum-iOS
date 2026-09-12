import SwiftUI
import UIKit

struct ShumProfileBlockRequest: Identifiable {
    let id = UUID()
    let peer: SpotchatPeer
    let card: SpotchatContactCard
    let waitsForTransientUI: Bool
}

struct ShumPeopleScreen: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var runtime: SpotchatRuntime
    let select: (SpotchatPeer) -> Void

    @State private var selectedPeer: SpotchatPeer?
    @State private var blockRequest: ShumProfileBlockRequest?
    @State private var showsSavedBlockInformation = false

    var body: some View {
        ZStack {
            Color.peopleListBackground.ignoresSafeArea()

            if !coordinator.isScaning {
                ShumPeopleUnavailable(
                    title: "Люди рядом скрыты",
                    message: "Включите видимость, чтобы находить людей поблизости.",
                    systemImage: "eye.slash",
                    actionTitle: "Найти людей"
                ) {
                    coordinator.setScanning(true)
                }
            } else if runtime.bluetoothState == .unauthorized {
                ShumPeopleUnavailable(
                    title: "Нужен Bluetooth",
                    message: "Разрешите Bluetooth для Shum в настройках iPhone.",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    actionTitle: "Открыть настройки"
                ) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
            } else if runtime.bluetoothState == .poweredOff {
                ShumPeopleUnavailable(
                    title: "Bluetooth выключен",
                    message: "Включите Bluetooth на iPhone, чтобы увидеть людей рядом.",
                    systemImage: "antenna.radiowaves.left.and.right.slash"
                )
            } else if runtime.peers.isEmpty {
                ShumPeopleUnavailable(
                    title: "Никого рядом",
                    message: "Откройте Shum на другом iPhone. Человек появится здесь, когда окажется поблизости.",
                    systemImage: "wave.3.up"
                )
            } else {
                peopleList
            }
        }
        .navigationTitle("Люди рядом")
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
        .alert("Сначала удалите из сохранённых", isPresented: $showsSavedBlockInformation) {
            Button("Понятно", role: .cancel) { }
        } message: {
            Text("Сохранённый профиль нельзя заблокировать. Удалите его из сохранённых и повторите.")
        }
    }

    private var peopleList: some View {
        List {
            Text("Здесь появляются пользователи Shum поблизости.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(runtime.peers) { peer in
                let card = runtime.permanent?.card(for: peer.id)
                let isSaved = card.map { runtime.permanent?.isSaved($0) == true } ?? false

                NativeSwipeInteractionRow {
                    ShumPeopleRow(
                        runtime: runtime,
                        peer: peer,
                        isSaved: isSaved,
                        cardAction: { selectedPeer = peer },
                        writeAction: { select(peer) }
                    )
                    .shumPeopleContextMenu(
                        runtime: runtime,
                        peer: peer,
                        card: card,
                        isSaved: isSaved,
                        writeAction: { select(peer) },
                        blockAction: {
                            requestBlock(
                                card,
                                peer: peer,
                                isSaved: isSaved,
                                waitsForTransientUI: false
                            )
                        }
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color(uiColor: .systemBackground))
                .listRowSeparator(.hidden)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if let card {
                        Button {
                            toggleSaved(card, peer: peer)
                        } label: {
                            ShumSwipeLabel(isSaved ? "Убрать" : "Сохранить", systemImage: isSaved ? "heart.slash" : "heart")
                        }
                        .tint(isSaved ? Color(uiColor: .systemGray) : .green)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: !isSaved) {
                    if let card {
                        if isSaved {
                            Button { showsSavedBlockInformation = true } label: {
                                ShumSwipeLabel("Сохранён", systemImage: "lock.fill")
                            }
                            .tint(Color(uiColor: .systemGray))
                        } else {
                            Button {
                                requestBlock(
                                    card,
                                    peer: peer,
                                    isSaved: false,
                                    waitsForTransientUI: true
                                )
                            } label: {
                                ShumSwipeLabel("Заблокировать", systemImage: "person.crop.circle.badge.xmark")
                            }
                            .tint(.red)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { runtime.tick() }
    }

    private func toggleSaved(_ card: SpotchatContactCard, peer: SpotchatPeer) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        do {
            _ = try runtime.permanent?.toggleSaved(
                card,
                avatar: runtime.profile(for: peer.id)?.avatar
            )
        } catch { runtime.error = error.localizedDescription }
    }

    private func requestBlock(
        _ card: SpotchatContactCard?,
        peer: SpotchatPeer,
        isSaved: Bool,
        waitsForTransientUI: Bool
    ) {
        guard let card else {
            runtime.error = "Дождитесь проверки профиля пользователя."
            return
        }
        if isSaved { showsSavedBlockInformation = true }
        else {
            blockRequest = ShumProfileBlockRequest(
                peer: peer,
                card: card,
                waitsForTransientUI: waitsForTransientUI
            )
        }
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
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    let isSaved: Bool
    let cardAction: () -> Void
    let writeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                cardAction()
            } label: {
                HStack(spacing: 12) {
                    ShumProfileAvatar(size: 52, imageData: runtime.profile(for: peer.id)?.avatar)
                    .shumSavedProfileBadge(isSaved: isSaved)

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

private extension View {
    func shumSavedProfileBadge(isSaved: Bool) -> some View {
        mask {
            Rectangle()
                .overlay(alignment: .bottomTrailing) {
                    if isSaved {
                        Circle().frame(width: 18, height: 18).offset(x: 2, y: 2).blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
        }
        .overlay(alignment: .bottomTrailing) {
            if isSaved {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
                    .offset(x: 2, y: 2)
            }
        }
    }
}

struct ShumProfileAvatar: View {
    let size: CGFloat
    let imageData: Data?

    var body: some View {
        Group {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.gray)
            }
        }
        .frame(width: size, height: size)
        .background(Color(uiColor: .secondarySystemBackground), in: Circle())
        .clipShape(Circle())
    }
}

private struct ShumDistanceLabel: View {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer

    var body: some View {
        Group {
            if let meters = runtime.distanceMeters(for: peer.id) {
                Text("\(meters) м")
                    .accessibilityLabel("Примерное расстояние: \(meters) метров")
            } else {
                Text(runtime.isNearby(peer.id) ? "Рядом" : "Не рядом")
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
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    let profileCard: SpotchatContactCard?
    var lastMetAt: Date?
    let write: () -> Void

    @State private var showPhoto = false

    init(
        runtime: SpotchatRuntime,
        peer: SpotchatPeer,
        card: SpotchatContactCard? = nil,
        lastMetAt: Date? = nil,
        write: @escaping () -> Void
    ) {
        self.runtime = runtime
        self.peer = peer
        self.profileCard = card
        self.lastMetAt = lastMetAt
        self.write = write
    }

    private var card: SpotchatContactCard? { profileCard ?? runtime.permanent?.card(for: peer.id) }
    private var isSaved: Bool { card.map { runtime.permanent?.isSaved($0) == true } ?? false }
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

                        ShumProfileAvatar(size: photoSize, imageData: avatar)
                            .contentShape(Circle())
                            .onTapGesture(perform: openPhoto)
                            .accessibilityLabel("Посмотреть фото")
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

                        RegistrationPrimaryButton(title: "Написать", action: write)
                            .frame(width: contentWidth)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .shumGeometryGroup()
                    .compositingGroup()
                }
                .padding(.top, 60)
                .offset(y: -10)
                .ignoresSafeArea(.keyboard, edges: .bottom)

                ZStack(alignment: .top) {
                    presenceInfo
                        .frame(width: contentWidth, height: 44, alignment: .leading)

                    HStack {
                        Spacer()
                        if let card {
                            Button { toggleSaved(card) } label: {
                                Image(systemName: isSaved ? "heart.fill" : "heart")
                                    .font(.system(size: 19, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .frame(width: 56, height: 44)
                                    .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isSaved ? "Убрать из сохранённых" : "Сохранить")
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.top, 8)
            }
        }
        .fullScreenCover(isPresented: $showPhoto) {
            if let avatar, let image = UIImage(data: avatar) {
                FullScreenPhotoView(isPresented: $showPhoto) {
                    Image(uiImage: image).resizable().scaledToFit()
                }
            }
        }
    }

    private var presenceInfo: some View {
        Group {
            if let lastMetAt, !runtime.isNearby(peer.id) {
                Text("Виделись \(lastMetAt.shumRelativeDescription)")
            } else {
                HStack(spacing: 8) {
                    Text(runtime.isNearby(peer.id) ? "Рядом" : "Не рядом")
                    if let meters = runtime.distanceMeters(for: peer.id) {
                        Text("\(meters) м")
                            .accessibilityLabel("Примерное расстояние: \(meters) метров")
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

    private func toggleSaved(_ card: SpotchatContactCard) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        do { _ = try runtime.permanent?.toggleSaved(card, avatar: avatar) }
        catch { runtime.error = error.localizedDescription }
    }
}

private struct ShumPersonContextMenuModifier: ViewModifier {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    let card: SpotchatContactCard?
    let isSaved: Bool
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
                    isSaved: isSaved,
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
            Label("Написать", systemImage: "paperplane")
                .foregroundStyle(.primary)
        }
        .tint(.primary)

        if let card {
            Button { toggleSaved(card) } label: {
                Label(
                    isSaved ? "Убрать из сохранённых" : "Сохранить",
                    systemImage: isSaved ? "heart.slash" : "heart"
                )
                .foregroundStyle(.primary)
            }
            .tint(.primary)
        }

        if let deleteAction {
            Divider()
            Button(action: deleteAction) {
                Label("Удалить", systemImage: "trash")
                    .foregroundStyle(.primary)
            }
            .tint(.primary)
        }

        Divider()

        if isSaved {
            Button(action: blockAction) {
                Label("Сначала удалите из сохранённых", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
            .tint(.secondary)
        } else {
            Button(role: .destructive, action: blockAction) {
                Label("Заблокировать", systemImage: "person.crop.circle.badge.xmark")
                    .foregroundStyle(.red)
            }
            .tint(.red)
        }
    }

    private func toggleSaved(_ card: SpotchatContactCard) {
        do {
            _ = try runtime.permanent?.toggleSaved(
                card,
                avatar: runtime.profile(for: peer.id)?.avatar
            )
        } catch { runtime.error = error.localizedDescription }
    }
}

private extension View {
    func shumPeopleContextMenu(
        runtime: SpotchatRuntime,
        peer: SpotchatPeer,
        card: SpotchatContactCard?,
        isSaved: Bool,
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
                isSaved: isSaved,
                lastMetAt: lastMetAt,
                deleteAction: deleteAction,
                writeAction: writeAction,
                blockAction: blockAction
            )
        )
    }
}

private struct ShumPersonContextPreview: View {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    let isSaved: Bool
    let lastMetAt: Date?

    private var sourceWidth: CGFloat { UIScreen.main.bounds.width }
    private var previewWidth: CGFloat { min(sourceWidth, max(320, sourceWidth - 32)) }
    private var previewScale: CGFloat { sourceWidth > 0 ? previewWidth / sourceWidth : 1 }

    var body: some View {
        HStack(spacing: 12) {
            ShumProfileAvatar(size: 52, imageData: runtime.profile(for: peer.id)?.avatar)
            .shumSavedProfileBadge(isSaved: isSaved)

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
    @ObservedObject var runtime: SpotchatRuntime

    @State private var selectedEncounter: SpotchatEncounter?
    @State private var conversationPeer: SpotchatPeer?
    @State private var pendingDelete: SpotchatEncounter?
    @State private var blockRequest: ShumProfileBlockRequest?
    @State private var showsClearConfirmation = false
    @State private var showsSavedBlockInformation = false

    private var encounters: [SpotchatEncounter] {
        runtime.permanent?.encounterHistory ?? []
    }

    var body: some View {
        ZStack {
            Color.peopleListBackground.ignoresSafeArea()

            if encounters.isEmpty {
                ShumPeopleUnavailable(
                    title: "Пока никого",
                    message: "Здесь появятся люди, которых Shum заметил рядом.",
                    systemImage: "clock.arrow.circlepath"
                )
            } else {
                encounterList
            }
        }
        .navigationTitle("Виделись")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showsClearConfirmation = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Очистить историю")
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
                conversationPeer = peer
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: conversationBinding) {
            if let conversationPeer {
                SpotchatConversationView(runtime: runtime, peer: conversationPeer)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .alert(
            "Удалить из «Виделись»?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) {
            encounter in
            Button("Отмена", role: .cancel) { pendingDelete = nil }
            Button("Очистить", role: .destructive) {
                runtime.permanent?.deleteEncounter(encounter.card)
                pendingDelete = nil
            }
        } message: {
            _ in
            Text("Карточка будет удалена из списка «Виделись».")
        }
        .alert("Очистить историю встреч?", isPresented: $showsClearConfirmation) {
            Button("Отмена", role: .cancel) { }
            Button("Очистить историю", role: .destructive) {
                runtime.permanent?.clearEncounters()
            }
        } message: {
            Text("Все сохранённые на этом устройстве встречи будут удалены.")
        }
        .shumProfileBlockSheet(runtime: runtime, request: $blockRequest)
        .alert("Сначала удалите из сохранённых", isPresented: $showsSavedBlockInformation) {
            Button("Понятно", role: .cancel) { }
        } message: {
            Text("Сохранённый профиль нельзя заблокировать. Удалите его из сохранённых и повторите.")
        }
        .task { runtime.permanent?.markEncountersViewed() }
    }

    private var encounterList: some View {
        List {
            Text("История хранится только на этом iPhone в зашифрованном виде.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(encounters) { encounter in
                let peer = encounter.peer
                let isSaved = runtime.permanent?.isSaved(encounter.card) == true

                NativeSwipeInteractionRow {
                    ShumStoredPersonRow(
                        runtime: runtime,
                        peer: peer,
                        isSaved: isSaved,
                        lastMetAt: encounter.lastSeen,
                        cardAction: { selectedEncounter = encounter },
                        writeAction: { conversationPeer = peer }
                    )
                    .shumPeopleContextMenu(
                        runtime: runtime,
                        peer: peer,
                        card: encounter.card,
                        isSaved: isSaved,
                        lastMetAt: encounter.lastSeen,
                        deleteAction: { pendingDelete = encounter },
                        writeAction: { conversationPeer = peer },
                        blockAction: {
                            if isSaved { showsSavedBlockInformation = true }
                            else {
                                blockRequest = ShumProfileBlockRequest(
                                    peer: peer,
                                    card: encounter.card,
                                    waitsForTransientUI: false
                                )
                            }
                        }
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color(uiColor: .systemBackground))
                .listRowSeparator(.hidden)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 80 }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { toggleSaved(encounter) } label: {
                        ShumSwipeLabel(isSaved ? "Убрать" : "Сохранить", systemImage: isSaved ? "heart.slash" : "heart")
                    }
                    .tint(isSaved ? Color(uiColor: .systemGray) : .green)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: !isSaved) {
                    Button { pendingDelete = encounter } label: {
                        ShumSwipeLabel("Очистить", systemImage: "trash")
                    }
                    .tint(Color(uiColor: .systemGray))

                    if isSaved {
                        Button { showsSavedBlockInformation = true } label: {
                            ShumSwipeLabel("Сохранён", systemImage: "lock.fill")
                        }
                        .tint(Color(uiColor: .systemGray2))
                    } else {
                        Button {
                            blockRequest = ShumProfileBlockRequest(
                                peer: peer,
                                card: encounter.card,
                                waitsForTransientUI: true
                            )
                        } label: {
                            ShumSwipeLabel("Заблокировать", systemImage: "person.crop.circle.badge.xmark")
                        }
                        .tint(.red)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var conversationBinding: Binding<Bool> {
        Binding(
            get: { conversationPeer != nil },
            set: { if !$0 { conversationPeer = nil } }
        )
    }

    private func toggleSaved(_ encounter: SpotchatEncounter) {
        do { _ = try runtime.permanent?.toggleSaved(encounter.card, avatar: encounter.avatar) }
        catch { runtime.error = error.localizedDescription }
    }
}

private struct ShumProfileBlockSheetModifier: ViewModifier {
    @ObservedObject var runtime: SpotchatRuntime
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
    @ObservedObject var runtime: SpotchatRuntime
    let request: ShumProfileBlockRequest
    let onClose: () -> Void
    let onBlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                ShumProfileAvatar(
                    size: 44,
                    imageData: runtime.profile(for: request.peer.id)?.avatar
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Заблокировать пользователя?")
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
                .accessibilityLabel("Закрыть")
            }

            VStack(spacing: 0) {
                Button(role: .destructive, action: onBlock) {
                    HStack(spacing: 18) {
                        Image(systemName: "person.crop.circle.badge.xmark")
                            .font(.system(size: 20, weight: .regular))
                            .frame(width: 22)

                        Text("Заблокировать")
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
        runtime: SpotchatRuntime,
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

struct ShumSavedProfilesView: View {
    @ObservedObject var runtime: SpotchatRuntime

    @State private var selectedProfile: SpotchatSavedProfile?
    @State private var conversationPeer: SpotchatPeer?
    @State private var showsSavedBlockInformation = false

    private var profiles: [SpotchatSavedProfile] {
        runtime.permanent?.savedProfiles ?? []
    }

    var body: some View {
        ZStack {
            Color.peopleListBackground.ignoresSafeArea()

            if profiles.isEmpty {
                ShumPeopleUnavailable(
                    title: "Нет сохранённых",
                    message: "Смахните профиль вправо в разделе «Люди» или «Виделись», чтобы сохранить его.",
                    systemImage: "heart"
                )
            } else {
                savedList
            }
        }
        .navigationTitle("Сохранённые")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedProfile) { profile in
            let peer = profile.peer
            ShumPeerCard(runtime: runtime, peer: peer, card: profile.card) {
                selectedProfile = nil
                conversationPeer = peer
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: conversationBinding) {
            if let conversationPeer {
                SpotchatConversationView(runtime: runtime, peer: conversationPeer)
                    .toolbar(.hidden, for: .tabBar)
            }
        }
        .alert("Сначала удалите из сохранённых", isPresented: $showsSavedBlockInformation) {
            Button("Понятно", role: .cancel) { }
        } message: {
            Text("Сохранённый профиль нельзя заблокировать. Удалите его из сохранённых и повторите.")
        }
    }

    private var savedList: some View {
        List {
            Text("Сохранённые профили доступны без интернета и остаются только на этом iPhone.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            ForEach(profiles) { profile in
                let peer = profile.peer

                NativeSwipeInteractionRow {
                    ShumStoredPersonRow(
                        runtime: runtime,
                        peer: peer,
                        isSaved: true,
                        cardAction: { selectedProfile = profile },
                        writeAction: { conversationPeer = peer }
                    )
                    .shumPeopleContextMenu(
                        runtime: runtime,
                        peer: peer,
                        card: profile.card,
                        isSaved: true,
                        writeAction: { conversationPeer = peer },
                        blockAction: { showsSavedBlockInformation = true }
                    )
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color(uiColor: .systemBackground))
                .listRowSeparator(.hidden)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 80 }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button { remove(profile) } label: {
                        ShumSwipeLabel("Убрать", systemImage: "heart.slash")
                    }
                    .tint(Color(uiColor: .systemGray))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var conversationBinding: Binding<Bool> {
        Binding(
            get: { conversationPeer != nil },
            set: { if !$0 { conversationPeer = nil } }
        )
    }

    private func remove(_ profile: SpotchatSavedProfile) {
        do { _ = try runtime.permanent?.toggleSaved(profile.card, avatar: profile.avatar) }
        catch { runtime.error = error.localizedDescription }
    }
}

private struct ShumStoredPersonRow: View {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    let isSaved: Bool
    var lastMetAt: Date?
    let cardAction: () -> Void
    let writeAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                cardAction()
            } label: {
                HStack(spacing: 12) {
                    ShumProfileAvatar(size: 52, imageData: runtime.profile(for: peer.id)?.avatar)
                    .shumSavedProfileBadge(isSaved: isSaved)

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

private extension SpotchatEncounter {
    var peer: SpotchatPeer {
        SpotchatPeer(id: card.peerID, name: card.name, lastConnected: lastSeen)
    }
}

private extension SpotchatSavedProfile {
    var peer: SpotchatPeer {
        SpotchatPeer(id: card.peerID, name: card.name, lastConnected: savedAt)
    }
}
