#if os(iOS)
import SwiftUI

// Current Spotchat chat list, adapted to Shum's navigation and palette.
enum SpotchatUIRoute: Hashable {
    case conversation(SpotchatPeer), nearby, newChat, requests
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
            case .nearby: ShumPeopleScreen(runtime: runtime) { open(.conversation($0)) }
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
    @State private var selectedPeer: SpotchatPeer?
    @State private var deleteChatPeer: SpotchatPeer?

    private var chats: [SpotchatPeer] {
        guard !search.isEmpty else { return runtime.chatPeers }
        return runtime.chatPeers.filter { runtime.displayName($0).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            Section {
                nearbyRow
                if let requests = runtime.permanent?.state.requests, !requests.isEmpty {
                    Button { open(.requests) } label: { Label("Приглашения: \(requests.count)", systemImage: "person.badge.plus") }
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
                                Button("Удалить", role: .destructive) { deleteChatPeer = peer }
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
                Image(systemName: "lock.fill")
                Text(runtime.internetConnected ? "Сквозное шифрование · Nostr подключён" : "Сквозное шифрование · Ожидаем сеть")
            }.font(.caption2).foregroundStyle(.secondary).padding(8)
        }
        .navigationTitle("Чаты")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Поиск")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { open(.newChat) } label: {
                    Label("Новый контакт", systemImage: "plus")
                }
                .foregroundStyle(.primary)
                .tint(.primary)
                .accessibilityIdentifier("spotchat.addContact")
            }
        }
        .sheet(item: $selectedPeer) { peer in
            ShumPeerCard(runtime: runtime, peer: peer) {
                selectedPeer = nil
                open(.conversation(peer))
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

    private var nearbyRow: some View {
        Button { open(.nearby) } label: {
            HStack(spacing: 12) {
                Image("PixelPeople")
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.white)
                Text("Люди рядом")
                    .font(.body)
                Spacer(minLength: 8)
                Text(String(runtime.peers.count))
                    .font(.body)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        .accessibilityLabel("Люди рядом: \(runtime.peers.count)")
        .accessibilityIdentifier("shum.nearby")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Здесь будут ваши чаты")
                .font(.headline)
            Text("Нажмите +, чтобы начать разговор, или откройте людей рядом.")
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
