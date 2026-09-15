#if os(iOS)
import SwiftUI
import UIKit
import BitFoundation

// Current Spotchat chat list, adapted to Shum's navigation and palette.
enum SpotchatUIRoute: Hashable {
    case conversation(SpotchatPeer), newChat, requests, ownQR
}

private struct ShumDirectoryRowID: Hashable {
    let folder: ShumChatFolder
    let peer: PeerID
}

struct SpotchatDestinationUI: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var runtime: SpotchatRuntime
    let route: SpotchatUIRoute
    let open: (SpotchatUIRoute) -> Void
    var body: some View {
        Group {
            switch route {
            case .conversation(let peer):
                SpotchatConversationView(runtime: runtime, peer: peer)
            case .newChat: SpotchatContactsView(runtime: runtime) { open(.conversation($0)) }
            case .requests: SpotchatContactRequestsView(runtime: runtime) { open(.conversation($0)) }
            case .ownQR:
                if let card = runtime.permanent?.ownCard {
                    SpotchatQRView(
                        card: card,
                        resolve: { locator, completion in
                            runtime.resolveContact(locator, completion: completion)
                        }
                    ) { scannedCard in
                        coordinator.invitation = scannedCard
                    }
                }
            }
        }
    }
}

struct SpotchatChatsUI: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var runtime: SpotchatRuntime
    let open: (SpotchatUIRoute) -> Void
    @State private var folder: ShumChatFolder = .all


    private var entries: [ShumDirectoryEntry] { runtime.directoryEntries }
    private var visible: [ShumDirectoryEntry] {
        entries.filter { $0.belongs(to: folder) }
    }

    var body: some View {
        ShumDirectoryList(runtime: runtime, folder: folder, entries: visible, open: open) {
            ShumChatFolderBar(selection: $folder, entries: entries)
                .padding(.vertical, 6)
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } empty: {
            emptyState
        }
        .refreshable { runtime.tick() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                Text(runtime.internetConnected
                     ? "Сквозное шифрование · Nostr подключён"
                     : "Сквозное шифрование · Ожидаем сеть")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(8)
        }
        .navigationTitle("Чаты")
        .navigationBarTitleDisplayMode(.inline)
        .shumOnChange(of: folder) { _, folder in
            if folder == .encounters { runtime.permanent?.markEncountersViewed() }
        }
        #if DEBUG && targetEnvironment(simulator)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-ShumPreviewPeople") { folder = .nearby }
        }
        #endif
    }

    private var emptyState: some View {
        ShumChatEmptyState(folder: folder) {
            switch folder {
            case .all, .invitations:
                open(.newChat)
            case .unread, .saved:
                withAnimation(.easeInOut(duration: 0.2)) { folder = .all }
            case .nearby, .encounters:
                break
            }
        }
        .frame(maxWidth: .infinity, minHeight: max(420, UIScreen.main.bounds.height * 0.54))
        .padding(.horizontal, 24)
    }
}

private struct ShumChatEmptyState: View {
    let folder: ShumChatFolder
    let action: () -> Void

    private let accent = Color(uiColor: .systemGreen)

    var body: some View {
        VStack(spacing: 0) {
            ShumPixelEmptyIcon(kind: iconKind)
                .foregroundStyle(.white)
                .frame(width: 88, height: 68)
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .padding(.top, 26)

            Text(message)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)

            if let status {
                Text(status)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
            } else if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.top, 20)
            }
        }
        .frame(maxWidth: 330)
        .accessibilityElement(children: .contain)
    }

    private var iconKind: ShumPixelEmptyIcon.Kind {
        switch folder {
        case .all: .chats
        case .nearby: .nearby
        case .unread: .read
        case .invitations: .invitation
        case .encounters: .encounters
        case .saved: .saved
        }
    }

    private var title: String {
        switch folder {
        case .all: "Пока тихо"
        case .nearby: "Никого рядом"
        case .unread: "Всё прочитано"
        case .invitations: "Нет приглашений"
        case .encounters: "Пока не встречались"
        case .saved: "Ничего не сохранено"
        }
    }

    private var message: String {
        switch folder {
        case .all: "Новые разговоры появятся здесь."
        case .nearby: "Поиск поблизости работает\nавтоматически."
        case .unread: "Новых сообщений пока нет."
        case .invitations: "Новые приглашения появятся здесь."
        case .encounters: "Встречи поблизости сохранятся здесь."
        case .saved: "Нужные профили можно оставить\nздесь."
        }
    }

    private var actionTitle: String? {
        switch folder {
        case .all, .invitations: "Добавить контакт"
        case .unread, .saved: "Все чаты"
        case .nearby, .encounters: nil
        }
    }

    private var status: String? {
        switch folder {
        case .encounters: "Все встречи за 24 часа"
        default: nil
        }
    }
}

/// Small bitmap drawings keep the empty states in Shum's pixel language without
/// introducing a second illustration palette.
struct ShumPixelEmptyIcon: View {
    enum Kind { case chats, contacts, nearby, read, invitation, encounters, saved }
    let kind: Kind

    private let unit: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let drawingSize = CGSize(width: 22 * unit, height: 17 * unit)
            let origin = CGPoint(
                x: (proxy.size.width - drawingSize.width) / 2,
                y: (proxy.size.height - drawingSize.height) / 2
            )
            Canvas(rendersAsynchronously: false) { context, _ in
                for pixel in pixels {
                    context.fill(
                        Path(CGRect(
                            x: origin.x + CGFloat(pixel.x) * unit,
                            y: origin.y + CGFloat(pixel.y) * unit,
                            width: unit,
                            height: unit
                        )),
                        with: .foreground
                    )
                }
            }
        }
    }

    private var pixels: [Pixel] {
        switch kind {
        case .chats:
            outline(x: 1, y: 2, width: 11, height: 8, tail: .left)
            + outline(x: 11, y: 7, width: 10, height: 7, tail: .right)
            + [Pixel(4, 6), Pixel(6, 6), Pixel(8, 6), Pixel(14, 10), Pixel(16, 10), Pixel(18, 10)]
        case .contacts:
            person(x: 3, y: 5) + person(x: 11, y: 5)
        case .nearby:
            person(x: 1, y: 5) + person(x: 16, y: 5)
            + [Pixel(10, 7), Pixel(12, 7), Pixel(13, 6), Pixel(13, 8), Pixel(14, 5), Pixel(14, 9)]
        case .read:
            line(from: Pixel(5, 2), to: Pixel(5, 14))
            + line(from: Pixel(6, 2), to: Pixel(16, 2))
            + line(from: Pixel(6, 9), to: Pixel(14, 9))
            + line(from: Pixel(16, 2), to: Pixel(16, 6))
            + [Pixel(12, 6), Pixel(13, 7), Pixel(14, 6), Pixel(15, 5), Pixel(16, 4)]
        case .invitation:
            person(x: 4, y: 3)
            + line(from: Pixel(15, 8), to: Pixel(15, 14))
            + line(from: Pixel(12, 11), to: Pixel(18, 11))
        case .encounters:
            person(x: 1, y: 5) + person(x: 16, y: 5)
            + [Pixel(10, 8), Pixel(12, 8), Pixel(11, 9), Pixel(10, 10), Pixel(12, 10)]
        case .saved:
            person(x: 2, y: 4) + heart(x: 13, y: 7)
        }
    }

    private func person(x: Int, y: Int) -> [Pixel] {
        outline(x: x + 2, y: y, width: 4, height: 4, tail: nil)
        + line(from: Pixel(x + 1, y + 5), to: Pixel(x + 6, y + 5))
        + line(from: Pixel(x, y + 6), to: Pixel(x, y + 9))
        + line(from: Pixel(x + 7, y + 6), to: Pixel(x + 7, y + 9))
        + line(from: Pixel(x, y + 9), to: Pixel(x + 7, y + 9))
    }

    private func heart(x: Int, y: Int) -> [Pixel] {
        [Pixel(x + 1, y), Pixel(x + 2, y), Pixel(x + 4, y), Pixel(x + 5, y),
         Pixel(x, y + 1), Pixel(x + 1, y + 1), Pixel(x + 2, y + 1), Pixel(x + 3, y + 1), Pixel(x + 4, y + 1), Pixel(x + 5, y + 1), Pixel(x + 6, y + 1),
         Pixel(x, y + 2), Pixel(x + 1, y + 2), Pixel(x + 2, y + 2), Pixel(x + 3, y + 2), Pixel(x + 4, y + 2), Pixel(x + 5, y + 2), Pixel(x + 6, y + 2),
         Pixel(x + 1, y + 3), Pixel(x + 2, y + 3), Pixel(x + 3, y + 3), Pixel(x + 4, y + 3), Pixel(x + 5, y + 3),
         Pixel(x + 2, y + 4), Pixel(x + 3, y + 4), Pixel(x + 4, y + 4), Pixel(x + 3, y + 5)]
    }

    private enum Tail { case left, right }

    private func outline(x: Int, y: Int, width: Int, height: Int, tail: Tail?) -> [Pixel] {
        var result = line(from: Pixel(x + 1, y), to: Pixel(x + width - 2, y))
        result += line(from: Pixel(x, y + 1), to: Pixel(x, y + height - 2))
        result += line(from: Pixel(x + width - 1, y + 1), to: Pixel(x + width - 1, y + height - 2))
        result += line(from: Pixel(x + 1, y + height - 1), to: Pixel(x + width - 2, y + height - 1))
        if tail == .left { result += [Pixel(x + 2, y + height), Pixel(x + 2, y + height + 1), Pixel(x + 3, y + height)] }
        if tail == .right { result += [Pixel(x + width - 3, y + height), Pixel(x + width - 3, y + height + 1), Pixel(x + width - 4, y + height)] }
        return result
    }

    private func line(from start: Pixel, to end: Pixel) -> [Pixel] {
        if start.x == end.x {
            return (min(start.y, end.y)...max(start.y, end.y)).map { Pixel(start.x, $0) }
        }
        return (min(start.x, end.x)...max(start.x, end.x)).map { Pixel($0, start.y) }
    }

    private struct Pixel: Hashable {
        let x: Int
        let y: Int
        init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    }
}

/// Both the directory and search use the same rows, swipe actions and confirmation presentation.
struct ShumDirectoryList<Header: View, Empty: View>: View {
    @ObservedObject var runtime: SpotchatRuntime
    let folder: ShumChatFolder
    let entries: [ShumDirectoryEntry]
    let open: (SpotchatUIRoute) -> Void
    @ViewBuilder let header: () -> Header
    @ViewBuilder let empty: () -> Empty
    @State private var selectedPeer: SpotchatPeer?
    @State private var invitation: SpotchatContactCard?
    @State private var pendingAction: DirectoryConfirmation?
    @State private var blockRequest: ShumProfileBlockRequest?
    @State private var savedBlockInformation = false

    var body: some View {
        List {
            header()
            if entries.isEmpty {
                empty().listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else {
                ForEach(entries) { entry in
                    directoryRow(entry)
                        .id(ShumDirectoryRowID(folder: folder, peer: entry.id))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.peopleListBackground)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $selectedPeer) { peer in
            ShumPeerCard(runtime: runtime, peer: peer) {
                selectedPeer = nil
                open(.conversation(peer))
            }
            .presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
        .sheet(item: $invitation) { card in
            SpotchatContactConfirmation(
                card: card,
                imageData: runtime.profile(for: card.peerID)?.avatar
            ) {
                if let peer = runtime.addContact(card, source: "invitation") {
                    invitation = nil
                    open(.conversation(peer))
                }
            }
        }
        .shumProfileBlockSheet(runtime: runtime, request: $blockRequest)
        .alert(pendingAction?.title ?? "", isPresented: Binding(
            get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }
        ), presenting: pendingAction) { action in
            Button("Отмена", role: .cancel) { pendingAction = nil }
            Button(action.buttonTitle, role: .destructive) { confirm(action); pendingAction = nil }
        } message: { action in Text(action.message) }
        .alert("Действие недоступно", isPresented: $savedBlockInformation) {
            Button("Понятно", role: .cancel) { }
        } message: {
            Text("Сохранённый чат нельзя очистить или заблокировать. Сначала уберите его из сохранённых.")
        }
    }

    private func directoryRow(_ entry: ShumDirectoryEntry) -> some View {
        NativeSwipeInteractionRow {
            Button { activate(entry) } label: {
                ShumDirectoryRow(runtime: runtime, entry: entry)
            }
            .buttonStyle(.plain)
            .contextMenu { menu(entry) } preview: {
                ShumDirectoryRow(runtime: runtime, entry: entry)
                    .frame(width: max(280, UIScreen.main.bounds.width - 32))
                    .background(Color.profileRowSwipeSurface, in: RoundedRectangle(cornerRadius: 26))
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.peopleListBackground)
        .listRowSeparator(.hidden)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if entry.card != nil {
                Button { toggleSaved(entry) } label: {
                    Label(entry.isSaved ? "Убрать" : "Сохранить", systemImage: entry.isSaved ? "heart.slash" : "heart")
                }.tint(entry.isSaved ? Color(uiColor: .systemGray) : .green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: !entry.isSaved) {
            trailingActions(entry)
        }
    }

    @ViewBuilder private func trailingActions(_ entry: ShumDirectoryEntry) -> some View {
        if let card = entry.card {
            if entry.isSaved {
                Button { savedBlockInformation = true } label: {
                    Label("Недоступно", systemImage: "lock.fill")
                }
                .tint(Color(uiColor: .systemGray))
            } else if entry.isInvitation {
                Button { pendingAction = .decline(card) } label: {
                    Label("Отклонить", systemImage: "xmark")
                }
                .tint(.red)

                Button { requestBlock(entry, afterSwipe: true) } label: {
                    Label("Заблокировать", systemImage: "person.crop.circle.badge.xmark")
                }
                .tint(.red)
            } else {
                Button { requestBlock(entry, afterSwipe: true) } label: {
                    Label("Заблокировать", systemImage: "person.crop.circle.badge.xmark")
                }
                .tint(.red)

                if canClear(entry) {
                    Button { pendingAction = .clear(card) } label: {
                        Label("Очистить", systemImage: "trash")
                    }
                    .tint(Color(uiColor: .systemGray))
                }
            }
        }
    }

    @ViewBuilder private func menu(_ entry: ShumDirectoryEntry) -> some View {
        Button { selectedPeer = entry.peer } label: {
            Label("Посмотреть профиль", systemImage: "person.crop.circle").foregroundStyle(.primary)
        }.tint(.primary)
        Button { activate(entry) } label: {
            Label(entry.isInvitation ? "Посмотреть приглашение" : "Написать", systemImage: "paperplane").foregroundStyle(.primary)
        }.tint(.primary)
        if let card = entry.card {
            Button { toggleSaved(entry) } label: {
                Label(entry.isSaved ? "Убрать из сохранённых" : "Сохранить", systemImage: entry.isSaved ? "heart.slash" : "heart").foregroundStyle(.primary)
            }.tint(.primary)
            if entry.isInvitation, !entry.isSaved {
                Button(role: .destructive) { pendingAction = .decline(card) } label: {
                    Label("Отклонить приглашение", systemImage: "xmark").foregroundStyle(.red)
                }
                .tint(.red)
            } else if !entry.isSaved, canClear(entry) {
                Button(role: .destructive) { pendingAction = .clear(card) } label: {
                    Label("Очистить", systemImage: "trash").foregroundStyle(.red)
                }
                .tint(.red)
            }
            Divider()
            if entry.isSaved {
                Button { savedBlockInformation = true } label: {
                    Label("Недоступно", systemImage: "lock.fill").foregroundStyle(.secondary)
                }.tint(.secondary)
            } else {
                Button(role: .destructive) { requestBlock(entry, afterSwipe: false) } label: {
                    Label("Заблокировать", systemImage: "person.crop.circle.badge.xmark").foregroundStyle(.red)
                }.tint(.red)
            }
        }
    }

    private func activate(_ entry: ShumDirectoryEntry) {
        if entry.isInvitation, let card = entry.card { invitation = card }
        else { open(.conversation(entry.peer)) }
    }
    private func toggleSaved(_ entry: ShumDirectoryEntry) {
        guard let card = entry.card else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        do { _ = try runtime.permanent?.toggleSaved(card, avatar: runtime.profile(for: entry.peer.id)?.avatar) }
        catch { runtime.error = error.localizedDescription }
    }
    private func requestBlock(_ entry: ShumDirectoryEntry, afterSwipe: Bool) {
        guard let card = entry.card else { return }
        if entry.isSaved { savedBlockInformation = true }
        else { blockRequest = ShumProfileBlockRequest(peer: entry.peer, card: card, waitsForTransientUI: afterSwipe) }
    }
    private func canClear(_ entry: ShumDirectoryEntry) -> Bool {
        entry.hasChat && !runtime.conversation(entry.peer.id).isEmpty
    }
    private func confirm(_ action: DirectoryConfirmation) {
        switch action {
        case .clear(let card):
            do { try runtime.permanent?.clearDirectoryEntry(card) }
            catch { runtime.error = error.localizedDescription }
        case .decline(let card):
            runtime.permanent?.dismissRequest(card)
        }
    }

}

private enum DirectoryConfirmation {
    case clear(SpotchatContactCard), decline(SpotchatContactCard)
    var title: String {
        switch self {
        case .clear: "Очистить чат?"
        case .decline: "Отклонить приглашение?"
        }
    }
    var buttonTitle: String {
        switch self {
        case .clear: "Очистить"
        case .decline: "Отклонить"
        }
    }
    var message: String {
        switch self {
        case .clear:
            "Чат, контакт и локальные записи будут удалены со всех папок на этом устройстве. Копии у собеседника сохранятся."
        case .decline:
            "Приглашение будет удалено. Пользователь не будет заблокирован."
        }
    }
}

struct ShumDirectoryRow: View {
    @ObservedObject var runtime: SpotchatRuntime
    let entry: ShumDirectoryEntry
    private var last: SpotchatMessage? { runtime.conversation(entry.peer.id).last }
    var body: some View {
        HStack(spacing: 12) {
            ShumProfileAvatar(size: 52, imageData: runtime.profile(for: entry.peer.id)?.avatar)
                .shumChatSavedBadge(isSaved: entry.isSaved)
                .overlay(alignment: .bottomTrailing) {
                    if entry.isNearby {
                        Circle().fill(.green).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color.peopleListBackground, lineWidth: 2.5))
                    }
                }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(runtime.displayName(entry.peer))
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let last {
                        Text(last.date, style: .time).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if let last, last.outgoing, !entry.isInvitation {
                        ShumChatReceipt(status: last.status)
                    }
                    Text(entry.isInvitation ? "Приглашение в чат" : last?.text ?? "Начать чат")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.unread > 0 || entry.isInvitation {
                        Text(entry.unread > 99 ? "99+" : String(max(entry.unread, entry.isInvitation ? 1 : 0)))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.black)
                            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(entry.isInvitation ? "Открыть приглашение" : "Открыть чат")
    }
}

private extension View {
    func shumChatSavedBadge(isSaved: Bool) -> some View {
        mask {
            Rectangle()
                .overlay(alignment: .bottomLeading) {
                    if isSaved {
                        Circle()
                            .frame(width: 18, height: 18)
                            .offset(x: -2, y: 2)
                            .blendMode(.destinationOut)
                    }
                }
                .compositingGroup()
        }
        .overlay(alignment: .bottomLeading) {
            if isSaved {
                Image(systemName: "heart.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
                    .offset(x: -2, y: 2)
            }
        }
    }
}
private struct ShumChatReceipt: View {
    let status: DeliveryStatus
    private var receiptDescription: String {
        switch status {
        case .read: "Прочитано"
        case .delivered: "Доставлено"
        case .sent: "Отправлено"
        case .failed: "Не доставлено"
        default: "Отправляется"
        }
    }
    var body: some View {
        Group {
            switch status {
            case .read:
                SpotchatDoubleCheck().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 10)
            case .delivered:
                SpotchatDoubleCheck().stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                    .frame(width: 16, height: 10)
            case .sent:
                Image(systemName: "checkmark").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
            default:
                Image(systemName: "clock").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .accessibilityLabel(receiptDescription)
    }
}

#endif
