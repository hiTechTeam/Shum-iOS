import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var chat: SpotchatRuntime
    @ObservedObject var profilePhotoViewModel: ProfilePhotoViewModel
    @State private var selectedTab = 1
    @State private var nearbyPath: [SpotchatUIRoute] = []
    @State private var pendingContactPeer: SpotchatPeer?
    @State private var chatsPath: [SpotchatUIRoute] = []
    @State private var showContacts = false
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $nearbyPath) {
                ShumPeopleScreen(runtime: chat) { peer in
                    withAnimation { nearbyPath.append(.conversation(peer)) }
                }
                .navigationDestination(for: SpotchatUIRoute.self) { route in
                    SpotchatDestinationUI(runtime: chat, route: route) { next in
                        withAnimation { nearbyPath.append(next) }
                    }
                }
            }
            .tabItem { Label("Рядом", image: "PixelPeople") }
            .badge(coordinator.isScaning ? chat.peers.count : 0)
            .tag(0)
            NavigationStack(path: $chatsPath) {
                SpotchatChatsUI(runtime: chat) { route in
                    if case .newChat = route { showContacts = true }
                    else { withAnimation { chatsPath.append(route) } }
                }
                .navigationDestination(for: SpotchatUIRoute.self) { route in
                    SpotchatDestinationUI(runtime: chat, route: route) { next in
                        withAnimation { chatsPath.append(next) }
                    }
                }
            }.tabItem { Label("Чаты", image: "PixelChats") }
                .badge(chat.chatPeers.reduce(0) { $0 + chat.unreadCount(for: $1.id) }).tag(1)
            NavigationStack {
                ProfileOverviewView(
                    chat: chat,
                    authCodeViewModel: coordinator.authCodeViewModel,
                    photoViewModel: profilePhotoViewModel
                )
                    .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            }.tabItem { Label("Профиль", image: "PixelProfile") }.tag(2)
        }
        .tint(.accentColor)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !chat.isReady {
                Button { coordinator.retryMessaging() } label: {
                    Label("Не удалось открыть сообщения. Повторить", shumSymbol: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.footnote).padding(12).frame(maxWidth: .infinity).background(.thinMaterial)
                }
            }
        }
        .sheet(isPresented: $showContacts, onDismiss: openPendingContact) {
            SpotchatContactsView(runtime: chat) { peer in
                pendingContactPeer = peer
                showContacts = false
            }
        }
        .sheet(item: $coordinator.invitation, onDismiss: openPendingContact) { card in
            SpotchatContactConfirmation(card: card) {
                if let peer = chat.addContact(card, source: "link") {
                    pendingContactPeer = peer
                    coordinator.invitation = nil
                }
            }
        }
        .alert("Shum", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
            Button("Понятно") { chat.error = nil }
        } message: { Text(chat.error ?? "") }
        #if DEBUG && targetEnvironment(simulator)
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-ShumPreviewPeople") { selectedTab = 0 }
            else if arguments.contains("-ShumPreviewProfile") { selectedTab = 2 }
            else if arguments.contains("-ShumPreviewChat"), let peer = chat.chatPeers.first {
                chatsPath = [.conversation(peer)]
            }
        }
        #endif
    }

    private func openPendingContact() {
        guard let peer = pendingContactPeer else { return }
        pendingContactPeer = nil
        selectedTab = 1
        DispatchQueue.main.async { withAnimation { chatsPath.append(.conversation(peer)) } }
    }
}
