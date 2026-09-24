import SwiftUI

struct MainContentView: View {
    @Environment(\.shumThemePalette) private var palette
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var chat: ShumRuntime
    @ObservedObject var profilePhotoViewModel: ProfilePhotoViewModel
    @State private var selectedTab = 1
    @State private var contactsPath: [ShumUIRoute] = []
    @State private var chatsPath: [ShumUIRoute] = []
    @State private var profilePath: [ShumProfileRoute] = []
    @State private var showContacts = false
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $contactsPath) {
                ShumContactsUI(runtime: chat) { route in
                    if case .newChat = route { showContacts = true }
                    else { contactsPath.push(route) }
                }
                .navigationDestination(for: ShumUIRoute.self) { route in
                    ShumDestinationUI(runtime: chat, route: route) { contactsPath.push($0) }
                }
            }
            .modifier(ShumPeerCardPresentationHost(runtime: chat))
            .shumProtectFromCapture(contactsPath.last?.containsMessages == true)
            .toolbar(contactsPath.isEmpty ? .visible : .hidden, for: .tabBar)
            .tabItem { tabLabel("Контакты", image: "PixelPeople", tab: 0) }.tag(0)

            NavigationStack(path: $chatsPath) {
                ShumChatsUI(runtime: chat) { route in
                    if case .newChat = route { showContacts = true }
                    else { chatsPath.push(route) }
                }
                .navigationDestination(for: ShumUIRoute.self) { route in
                    ShumDestinationUI(runtime: chat, route: route) { chatsPath.push($0) }
                }
            }
            .modifier(ShumPeerCardPresentationHost(runtime: chat))
            .shumProtectFromCapture(chatsPath.last?.containsMessages ?? true)
            .toolbar(chatsPath.isEmpty ? .visible : .hidden, for: .tabBar)
            .tabItem { tabLabel("Чаты", image: "PixelChats", tab: 1) }
                .badge(chat.directoryEntries.reduce(0) {
                    $0 + max($1.unread, $1.invitationAwaitingResponse ? 1 : 0)
                }).tag(1)
            NavigationStack(path: $profilePath) {
                ProfileOverviewView(
                    chat: chat,
                    authCodeViewModel: coordinator.authCodeViewModel,
                    photoViewModel: profilePhotoViewModel,
                    open: { profilePath.push($0) }
                )
                .navigationDestination(for: ShumProfileRoute.self) { route in
                    profileDestination(route)
                }
            }
            .modifier(ShumPeerCardPresentationHost(runtime: chat))
            .shumProtectFromCapture(protectsProfileConversation)
            .toolbar(
                profilePath.last?.hidesTabBar == true ? .hidden : .visible,
                for: .tabBar
            )
            .tabItem { tabLabel("Профиль", image: "PixelProfile", tab: 2) }.tag(2)
        }
        .tint(palette.accent)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !chat.isReady {
                Button { coordinator.retryMessaging() } label: {
                    Label("Не удалось открыть сообщения. Повторить", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.footnote).padding(12).frame(maxWidth: .infinity).background(.thinMaterial)
                }
            }
        }
        .sheet(isPresented: $showContacts) {
            ShumContactsView(runtime: chat, showOwnQR: {
                let sourceTab = selectedTab
                showContacts = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if sourceTab == 0 {
                        contactsPath.push(.ownQR)
                    } else {
                        chatsPath.push(.ownQR)
                    }
                }
            }) { peer in
                showContacts = false; selectedTab = 1
                chatsPath.push(.conversation(peer))
            }
            .shumAllowsScreenshots()
        }
        .sheet(item: $coordinator.invitation) { card in
            ShumContactConfirmation(
                card: card,
                imageData: chat.profile(for: card.peerID)?.avatar,
                isExistingContact: isExistingContact(card)
            ) {
                openScannedContact(card)
            }
            .shumAllowsScreenshots()
        }
        .alert("Shum", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
            Button("Понятно") { chat.error = nil }
        } message: { Text(chat.error ?? "") }
        .shumOnChange(of: coordinator.nearbyNotificationNavigationRequest) {
            _, _ in
            selectedTab = 1
            chatsPath.removeAll()
        }
        .shumOnChange(of: coordinator.chatNotificationPeerID) {
            _, peerID in
            openNotificationChat(peerID)
        }
        .onAppear {
            openNotificationChat(coordinator.chatNotificationPeerID)
        }
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

    private var protectsProfileConversation: Bool {
        if case .conversation = profilePath.last { return true }
        return false
    }

    private func tabLabel(_ title: String, image name: String, tab: Int) -> some View {
        Label {
            Text(title)
        } icon: {
            if let image = UIImage(named: name) {
                // A visibility change refreshes the tab bar. Bake the theme
                // color into the pixel art so UIKit cannot flash its gray tint.
                Image(uiImage: image.withTintColor(
                    tabIconColor(isSelected: selectedTab == tab),
                    renderingMode: .alwaysOriginal
                ))
            } else {
                Image(name)
            }
        }
    }

    private func tabIconColor(isSelected: Bool) -> UIColor {
        if isSelected {
            return palette.tabBarIconUIColor ?? palette.accentUIColor
        }
        if #available(iOS 26.0, *) {
            return palette.tabBarIconUIColor
                ?? (palette.colorScheme == .dark ? .white : .black)
        }
        return .systemGray
    }

    private func isExistingContact(_ card: ShumContactCard) -> Bool {
        chat.permanent?.state.contacts.contains { $0.id == card.id } == true
    }

    private func openNotificationChat(_ peerID: String?) {
        guard let peerID,
              let entry = chat.directoryEntries.first(where: {
                  $0.peer.id.id == peerID
              }) else { return }
        selectedTab = 1
        chatsPath = [.conversation(entry.peer)]
        coordinator.clearChatNotificationPeerID()
    }

    @ViewBuilder
    private func profileDestination(_ route: ShumProfileRoute) -> some View {
        switch route {
        case .encounters:
            ShumEncounterHistoryView(runtime: chat) { peer in
                profilePath.push(.conversation(peer))
            }
        case .conversation(let peer):
            ShumConversationView(runtime: chat, peer: peer)
                .toolbar(.hidden, for: .tabBar)
        case .ownQR:
            if let card = chat.permanent?.ownCard {
                ShumQRView(
                    card: card,
                    resolve: { locator, completion in
                        chat.resolveContact(locator, completion: completion)
                    }
                ) { scannedCard in
                    coordinator.invitation = scannedCard
                }
            }
        }
    }

    private func openScannedContact(_ card: ShumContactCard) {
        let peer: ShumPeer
        if isExistingContact(card) {
            peer = ShumPeer(id: card.peerID, name: card.name, lastConnected: Date())
        } else {
            guard let added = chat.addContact(card, source: "link") else { return }
            peer = added
        }
        coordinator.invitation = nil
        selectedTab = 1
        // An explicitly accepted invitation can replace a chat already open
        // from a notification/deep link; it is not another tap on its source list.
        chatsPath = [.conversation(peer)]
    }

}
