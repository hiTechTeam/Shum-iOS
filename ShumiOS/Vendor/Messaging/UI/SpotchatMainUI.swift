#if os(iOS)
import SwiftUI

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
    @ObservedObject var runtime: SpotchatRuntime
    let open: (SpotchatUIRoute) -> Void
    @State private var search = ""
    @State private var isSearchPresented = false
    @State private var unreadOnly = false
    @State private var pendingConversation: SpotchatPeer?
    @State private var selectedPeer: SpotchatPeer?
    @State private var deleteChatPeer: SpotchatPeer?

    private var chats: [SpotchatPeer] {
        runtime.chatPeers.filter { peer in
            (!unreadOnly || runtime.unreadCount(for: peer.id) > 0)
                && (search.isEmpty || runtime.displayName(peer).localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            filterRow
            if let requests = runtime.permanent?.state.requests, !requests.isEmpty {
                Section {
                    Button { open(.requests) } label: { Label("Приглашения: \(requests.count)", shumSymbol: "person.badge.plus") }
                }
            }

            Section {
                if chats.isEmpty {
                    emptyState
                } else {
                    ForEach(chats) { peer in
                        Button { open(.conversation(peer)) } label: {
                            SpotchatChatRowUI(runtime: runtime, peer: peer)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Посмотреть профиль") { selectedPeer = peer }
                            if runtime.permanent != nil {
                                Button("Удалить чат", role: .destructive) { deleteChatPeer = peer }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if runtime.permanent != nil {
                                Button(role: .destructive) { deleteChatPeer = peer } label: { ShumSwipeLabel(title: "Удалить", symbol: "trash") }
                                    .tint(.red)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 11, leading: 0, bottom: 11, trailing: 0))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.visible)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 72 }
                        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
                    }
                }
            }
            .listSectionSeparator(.hidden, edges: .top)
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 6) {
                Image(shumSymbol: "lock.fill").resizable().scaledToFit().frame(width: 11, height: 11)
                Text(runtime.internetConnected ? "Сквозное шифрование · Nostr подключён" : "Сквозное шифрование · Ожидаем сеть")
            }.font(.caption2).foregroundStyle(.secondary).padding(8)
        }
        .navigationTitle("Чаты")
        .navigationBarTitleDisplayMode(.large)
        .background(ShumChatSearchController(text: $search, isPresented: $isSearchPresented).frame(width: 0, height: 0))
        .onDisappear { isSearchPresented = false }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isSearchPresented = true } label: { Image(shumSymbol: "magnifyingglass") }
                    .tint(.primary)
                    .accessibilityLabel("Поиск")
                    .accessibilityIdentifier("shum.search")
            }
            if #available(iOS 26.0, *) { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { open(.newChat) } label: {
                    Label("Новый контакт", shumSymbol: "plus")
                }
                .foregroundStyle(.primary)
                .tint(.primary)
                .accessibilityIdentifier("spotchat.addContact")
            }
        }
        .sheet(item: $selectedPeer, onDismiss: {
            guard let peer = pendingConversation else { return }
            pendingConversation = nil
            withAnimation { open(.conversation(peer)) }
        }) { peer in
            ShumPeerCard(runtime: runtime, peer: peer) {
                pendingConversation = peer
                selectedPeer = nil
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Удалить чат?",
            isPresented: Binding(
                get: { deleteChatPeer != nil },
                set: { if !$0 { deleteChatPeer = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let peer = deleteChatPeer {
                Button("Удалить чат", role: .destructive) {
                    if let card = runtime.permanent?.card(for: peer.id) {
                        do {
                            try runtime.permanent?.deleteConversation(with: card)
                        } catch {
                            runtime.error = error.localizedDescription
                        }
                    }
                    deleteChatPeer = nil
                }
            }
            Button("Отмена", role: .cancel) { deleteChatPeer = nil }
        } message: {
            Text("История и очередь будут удалены на этом iPhone. Контакт и копии у собеседника сохранятся.")
        }
    }

    private var filterRow: some View {
        HStack(spacing: 8) {
            filterButton("Все", unread: false)
            filterButton("Непрочитанное", unread: true)
            Spacer(minLength: 0)
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 16, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listSectionSeparator(.hidden)
    }

    private func filterButton(_ title: String, unread: Bool) -> some View {
        let selected = unreadOnly == unread
        return Button { unreadOnly = unread } label: {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(selected ? Color.accentColor.opacity(0.15) : Color(.secondarySystemGroupedBackground), in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.2) : Color(.separator).opacity(0.5), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(shumSymbol: "bubble.left.and.bubble.right").resizable().scaledToFit().frame(width: 34, height: 34)
                .foregroundStyle(Color.accentColor)
            Text(!search.isEmpty ? "Ничего не найдено" : unreadOnly ? "Нет непрочитанных чатов" : "Здесь будут ваши чаты")
                .font(.headline)
            Text(!search.isEmpty ? "Попробуйте другое имя." : unreadOnly ? "Все сообщения прочитаны." : "Нажмите +, чтобы начать разговор, или откройте вкладку «Рядом».")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .listRowBackground(Color.clear)
    }
}

private struct SpotchatChatRowUI: View {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer

    private var last: SpotchatMessage? { runtime.conversation(peer.id).last }
    private var unread: Int { runtime.unreadCount(for: peer.id) }

    var body: some View {
        HStack(spacing: 14) {
            SpotchatAvatar(
                name: runtime.displayName(peer),
                size: 58,
                nearby: runtime.isNearby(peer.id),
                imageData: runtime.profile(for: peer.id)?.avatar
            )
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(runtime.displayName(peer))
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let last {
                        Text(last.date, style: .time)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Text(last.map { ($0.outgoing ? "Вы: " : "") + $0.text } ?? "Начните разговор")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : String(unread))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 21, minHeight: 21)
                            .background(Color.accentColor, in: Capsule())
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(unread > 0 ? "Непрочитанных: \(unread). Открыть чат" : "Открыть чат")
    }
}

#endif
