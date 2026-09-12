#if os(iOS)
import SwiftUI
import UIKit

// Current Spotchat chat list, adapted to Shum's navigation and palette.
enum SpotchatUIRoute: Hashable {
    case conversation(SpotchatPeer), newChat, requests
}
struct SpotchatDestinationUI: View {
    @ObservedObject var runtime: SpotchatRuntime
    let route: SpotchatUIRoute
    let open: (SpotchatUIRoute) -> Void
    var body: some View {
        Group {
            switch route {
            case .conversation(let peer):
                SpotchatConversationView(runtime: runtime, peer: peer)
                    .toolbar(.hidden, for: .tabBar)
            case .newChat: SpotchatContactsView(runtime: runtime) { open(.conversation($0)) }
            case .requests: SpotchatContactRequestsView(runtime: runtime) { open(.conversation($0)) }
            }
        }
    }
}

struct SpotchatChatsUI: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var runtime: SpotchatRuntime
    let open: (SpotchatUIRoute) -> Void
    @State private var search = ""
    @State private var folder: ShumChatFolder = .all
    @State private var selectedPeer: SpotchatPeer?
    @State private var invitation: SpotchatContactCard?
    @State private var pendingAction: DirectoryConfirmation?
    @State private var blockRequest: ShumProfileBlockRequest?
    @State private var savedBlockInformation = false

    private var entries: [ShumDirectoryEntry] { runtime.directoryEntries }
    private var visible: [ShumDirectoryEntry] {
        entries.filter { $0.belongs(to: folder) && (search.isEmpty || runtime.displayName($0.peer).localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        List {
            if visible.isEmpty {
                emptyState.listRowBackground(Color.clear).listRowSeparator(.hidden)
            } else {
                ForEach(visible) { entry in
                    directoryRow(entry)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.peopleListBackground)
        .safeAreaInset(edge: .top, spacing: 0) {
            ShumChatFolderBar(selection: $folder, entries: entries)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { runtime.tick() }
        .navigationTitle("Чаты")
        .navigationBarTitleDisplayMode(.large)
        .modifier(ShumCompactChatSearch(text: $search))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { open(.newChat) } label: { Label("Новый контакт", systemImage: "plus") }
                    .foregroundStyle(.primary).tint(.primary)
                    .accessibilityIdentifier("spotchat.addContact")
            }
        }
        .sheet(item: $selectedPeer) { peer in
            ShumPeerCard(runtime: runtime, peer: peer) {
                selectedPeer = nil
                open(.conversation(peer))
            }
            .presentationDetents([.medium]).presentationDragIndicator(.visible)
        }
        .sheet(item: $invitation) { card in
            SpotchatContactConfirmation(card: card) {
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
        .alert("Сначала удалите из сохранённых", isPresented: $savedBlockInformation) {
            Button("Понятно", role: .cancel) { }
        } message: {
            Text("Сохранённый профиль нельзя заблокировать. Удалите его из сохранённых и повторите.")
        }
        .onChange(of: folder) { value in
            if value == .encounters { runtime.permanent?.markEncountersViewed() }
        }
        #if DEBUG && targetEnvironment(simulator)
        .onAppear {
            if ProcessInfo.processInfo.arguments.contains("-ShumPreviewPeople") { folder = .nearby }
        }
        #endif
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
            if entry.card != nil, folder != .saved {
                Button { toggleSaved(entry) } label: {
                    ShumSwipeLabel(entry.isSaved ? "Убрать" : "Сохранить", systemImage: entry.isSaved ? "heart.slash" : "heart")
                }.tint(entry.isSaved ? Color(uiColor: .systemGray) : .green)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: folder != .nearby || !entry.isSaved) {
            trailingActions(entry)
        }
    }

    @ViewBuilder private func trailingActions(_ entry: ShumDirectoryEntry) -> some View {
        if let card = entry.card {
            if folder == .saved {
                Button { toggleSaved(entry) } label: { ShumSwipeLabel("Убрать", systemImage: "heart.slash") }
                    .tint(Color(uiColor: .systemGray))
            } else {
                if folder == .encounters {
                    Button { pendingAction = .clearEncounter(card) } label: { ShumSwipeLabel("Очистить", systemImage: "trash") }
                        .tint(Color(uiColor: .systemGray))
                } else if entry.isInvitation {
                    Button { pendingAction = .decline(card) } label: { ShumSwipeLabel("Отклонить", systemImage: "xmark") }
                        .tint(.red)
                } else if entry.hasChat, folder != .nearby {
                    Button { pendingAction = .deleteChat(card) } label: { ShumSwipeLabel("Удалить", systemImage: "trash") }
                        .tint(.red)
                }
                Button { requestBlock(entry, afterSwipe: true) } label: {
                    ShumSwipeLabel(entry.isSaved ? "Сохранён" : "Заблокировать", systemImage: entry.isSaved ? "lock.fill" : "person.crop.circle.badge.xmark")
                }.tint(entry.isSaved ? Color(uiColor: .systemGray) : .red)
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
            if folder == .encounters {
                Button { pendingAction = .clearEncounter(card) } label: {
                    Label("Очистить", systemImage: "trash").foregroundStyle(.primary)
                }.tint(.primary)
            } else if entry.isInvitation {
                Button(role: .destructive) { pendingAction = .decline(card) } label: {
                    Label("Отклонить приглашение", systemImage: "xmark").foregroundStyle(.red)
                }.tint(.red)
            } else if entry.hasChat {
                Button(role: .destructive) { pendingAction = .deleteChat(card) } label: {
                    Label("Удалить чат", systemImage: "trash").foregroundStyle(.red)
                }.tint(.red)
            }
            Divider()
            if entry.isSaved {
                Button { savedBlockInformation = true } label: {
                    Label("Сначала удалите из сохранённых", systemImage: "lock.fill").foregroundStyle(.secondary)
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
    private func confirm(_ action: DirectoryConfirmation) {
        switch action {
        case .clearEncounter(let card): runtime.permanent?.deleteEncounter(card)
        case .decline(let card): runtime.permanent?.dismissRequest(card)
        case .deleteChat(let card):
            do { try runtime.permanent?.deleteConversation(with: card) }
            catch { runtime.error = error.localizedDescription }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(search.isEmpty ? emptyTitle : "Ничего не найдено").font(.headline)
            if folder == .nearby, search.isEmpty {
                Text(!coordinator.isScaning ? "Включите видимость, чтобы находить людей поблизости." : runtime.bluetoothState == .poweredOff ? "Включите Bluetooth на iPhone." : "Здесь появятся пользователи Shum поблизости.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if !coordinator.isScaning {
                    Button("Найти людей") { coordinator.setScanning(true) }.buttonStyle(.bordered)
                } else if runtime.bluetoothState == .unauthorized {
                    Button("Открыть настройки") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 44).padding(.horizontal, 24)
    }
    private var emptyTitle: String {
        switch folder {
        case .all: "Здесь будут ваши чаты"
        case .unread: "Всё прочитано"
        case .invitations: "Нет приглашений"
        case .nearby: "Никого рядом"
        case .encounters: "Пока не встречались"
        case .saved: "Нет сохранённых"
        }
    }
}

private enum DirectoryConfirmation {
    case deleteChat(SpotchatContactCard), clearEncounter(SpotchatContactCard), decline(SpotchatContactCard)
    var title: String {
        switch self {
        case .deleteChat: "Удалить чат?"
        case .clearEncounter: "Удалить из «Виделись»?"
        case .decline: "Отклонить приглашение?"
        }
    }
    var buttonTitle: String {
        switch self {
        case .deleteChat: "Удалить чат"
        case .clearEncounter: "Очистить"
        case .decline: "Отклонить"
        }
    }
    var message: String {
        switch self {
        case .deleteChat: "История и очередь будут удалены на этом iPhone. Контакт и копии у собеседника сохранятся."
        case .clearEncounter: "Карточка будет удалена из списка «Виделись»."
        case .decline: "Приглашение будет удалено. Пользователь не будет заблокирован."
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(runtime.displayName(entry.peer))
                        .font(.system(size: 15, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.isNearby {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 5, height: 5)
                            Text("Рядом").font(.system(size: 12))
                        }.foregroundStyle(.green)
                    } else if let last {
                        Text(last.date, style: .time).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text(entry.isInvitation ? "Приглашение в чат" : last.map { ($0.outgoing ? "Вы: " : "") + $0.text } ?? "Начать чат")
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    if entry.unread > 0 || entry.isInvitation {
                        Text(String(max(entry.unread, entry.isInvitation ? 1 : 0)))
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
private struct ShumCompactChatSearch: ViewModifier {
    @Binding var text: String

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .searchable(text: $text, placement: .toolbar, prompt: "Поиск")
                .searchToolbarBehavior(.minimize)
                .toolbar {
                    DefaultToolbarItem(kind: .search, placement: .topBarTrailing)
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
        } else {
            content.searchable(text: $text, placement: .toolbar, prompt: "Поиск")
        }
    }
}


#endif
