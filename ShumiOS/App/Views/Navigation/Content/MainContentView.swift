import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var chat: SpotchatRuntime
    @ObservedObject var profilePhotoViewModel: ProfilePhotoViewModel
    @State private var selectedTab = 1
    @State private var contactsPath: [SpotchatUIRoute] = []
    @State private var chatsPath: [SpotchatUIRoute] = []
    @State private var showContacts = false
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $contactsPath) {
                ShumContactsUI(runtime: chat) { route in
                    if case .newChat = route { showContacts = true }
                    else { contactsPath.append(route) }
                }
                .navigationDestination(for: SpotchatUIRoute.self) { route in
                    SpotchatDestinationUI(runtime: chat, route: route) { contactsPath.append($0) }
                }
            }
            .toolbar(contactsPath.isEmpty ? .visible : .hidden, for: .tabBar)
            .tabItem { Label("Контакты", image: "PixelPeople") }.tag(0)

            NavigationStack(path: $chatsPath) {
                SpotchatChatsUI(runtime: chat) { route in
                    if case .newChat = route { showContacts = true }
                    else { chatsPath.append(route) }
                }
                .navigationDestination(for: SpotchatUIRoute.self) { route in
                    SpotchatDestinationUI(runtime: chat, route: route) { chatsPath.append($0) }
                }
            }
            .toolbar(chatsPath.isEmpty ? .visible : .hidden, for: .tabBar)
            .tabItem { Label("Чаты", image: "PixelChats") }
                .badge(chat.directoryEntries.reduce(0) { $0 + max($1.unread, $1.isInvitation ? 1 : 0) }).tag(1)
            NavigationStack {
                ProfileOverviewView(
                    chat: chat,
                    authCodeViewModel: coordinator.authCodeViewModel,
                    photoViewModel: profilePhotoViewModel
                )
            }.tabItem { Label("Профиль", image: "PixelProfile") }.tag(2)
        }
        .tint(.accentColor)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !chat.isReady {
                Button { coordinator.retryMessaging() } label: {
                    Label("Не удалось открыть сообщения. Повторить", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.footnote).padding(12).frame(maxWidth: .infinity).background(.thinMaterial)
                }
            }
        }
        .sheet(isPresented: $showContacts) {
            SpotchatContactsView(runtime: chat, showOwnQR: {
                let sourceTab = selectedTab
                showContacts = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if sourceTab == 0 {
                        contactsPath.append(.ownQR)
                    } else {
                        chatsPath.append(.ownQR)
                    }
                }
            }) { peer in
                showContacts = false; selectedTab = 1
                chatsPath.append(.conversation(peer))
            }
        }
        .sheet(item: $coordinator.invitation) { card in
            SpotchatContactConfirmation(card: card) {
                if let peer = chat.addContact(card, source: "link") {
                    coordinator.invitation = nil; selectedTab = 1; chatsPath.append(.conversation(peer))
                }
            }
        }
        .alert("Shum", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
            Button("Понятно") { chat.error = nil }
        } message: { Text(chat.error ?? "") }
        #if DEBUG && targetEnvironment(simulator)
        .onAppear {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-ShumPreviewPeople") { selectedTab = 1 }
            else if arguments.contains("-ShumPreviewProfile") { selectedTab = 2 }
            else if arguments.contains("-ShumPreviewChat"), let peer = chat.chatPeers.first {
                chatsPath = [.conversation(peer)]
            }
        }
        #endif
    }

}
