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
            if let requests = runtime.permanent?.state.requests, !requests.isEmpty {
                Section {
                    Button { open(.requests) } label: { Label("Приглашения: \(requests.count)", systemImage: "person.badge.plus") }
                }
            }

            Section {
                if chats.isEmpty {
                    emptyState
                } else {
                    ForEach(chats) { peer in
                        NativeSwipeInteractionRow {
                            Button { open(.conversation(peer)) } label: {
                                SpotchatChatRowUI(runtime: runtime, peer: peer)
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 11)
                            .shumChatRowContextMenu(
                                runtime: runtime,
                                peer: peer,
                                profileAction: { selectedPeer = peer },
                                deleteAction: runtime.permanent == nil
                                    ? nil
                                    : { deleteChatPeer = peer }
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if runtime.permanent != nil {
                                Button { deleteChatPeer = peer } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color(uiColor: .systemBackground))
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
        .modifier(ShumCompactChatSearch(text: $search))
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
        .alert(
            "Удалить чат?",
            isPresented: Binding(
                get: { deleteChatPeer != nil },
                set: { if !$0 { deleteChatPeer = nil } }
            ),
            presenting: deleteChatPeer
        ) {
            peer in
            Button("Отмена", role: .cancel) { deleteChatPeer = nil }
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
        } message: {
            _ in
            Text("История и очередь будут удалены на этом iPhone. Контакт и копии у собеседника сохранятся.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text("Здесь будут ваши чаты")
                .font(.headline)
            Text("Нажмите +, чтобы начать разговор, или откройте вкладку «Рядом».")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .listRowBackground(Color.clear)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(unread > 0 ? "Непрочитанных: \(unread). Открыть чат" : "Открыть чат")
    }
}

private struct ShumChatRowContextMenuModifier: ViewModifier {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    let profileAction: () -> Void
    let deleteAction: (() -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.contextMenu { menu } preview: {
                ShumChatRowContextPreview(runtime: runtime, peer: peer)
            }
        } else {
            content.contextMenu { menu }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(action: profileAction) {
            Label("Посмотреть профиль", systemImage: "person.crop.circle")
                .foregroundStyle(.primary)
        }
        .tint(.primary)

        if let deleteAction {
            Divider()

            Button(role: .destructive, action: deleteAction) {
                Label("Удалить чат", systemImage: "trash")
                    .foregroundStyle(.red)
            }
            .tint(.red)
        }
    }
}

private struct ShumChatRowContextPreview: View {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer

    private var sourceWidth: CGFloat { UIScreen.main.bounds.width }
    private var previewWidth: CGFloat { min(sourceWidth, max(320, sourceWidth - 32)) }
    private var previewScale: CGFloat { sourceWidth > 0 ? previewWidth / sourceWidth : 1 }

    var body: some View {
        SpotchatChatRowUI(runtime: runtime, peer: peer)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(width: sourceWidth, height: 80)
            .background(
                Color(uiColor: .tertiarySystemBackground),
                in: RoundedRectangle(cornerRadius: 26, style: .continuous)
            )
            .scaleEffect(previewScale)
            .frame(width: previewWidth, height: 80 * previewScale)
    }
}

private extension View {
    func shumChatRowContextMenu(
        runtime: SpotchatRuntime,
        peer: SpotchatPeer,
        profileAction: @escaping () -> Void,
        deleteAction: (() -> Void)?
    ) -> some View {
        modifier(
            ShumChatRowContextMenuModifier(
                runtime: runtime,
                peer: peer,
                profileAction: profileAction,
                deleteAction: deleteAction
            )
        )
    }
}

#endif
