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
    @State private var showSecurity = false
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
            .modifier(ShumPeerPhotoPresentationHost())
            .toolbar(contactsPath.isEmpty ? .visible : .hidden, for: .tabBar)
            .tabItem { tabLabel("Контакты".localized, image: "PixelPeople", tab: 0) }.tag(0)

            NavigationStack(path: $chatsPath) {
                ShumChatsUI(runtime: chat) { route in
                    if case .newChat = route { showContacts = true }
                    else { chatsPath.push(route) }
                }
                .navigationDestination(for: ShumUIRoute.self) { route in
                    ShumDestinationUI(runtime: chat, route: route) { chatsPath.push($0) }
                }
            }
            .modifier(ShumPeerPhotoPresentationHost())
            .toolbar(chatsPath.isEmpty ? .visible : .hidden, for: .tabBar)
            .tabItem { tabLabel("Чаты".localized, image: "PixelChats", tab: 1,
                                badge: chat.directoryEntries.badgeCount) }.tag(1)
            NavigationStack(path: $profilePath) {
                ProfileOverviewView(
                    chat: chat,
                    authCodeViewModel: coordinator.authCodeViewModel,
                    photoViewModel: profilePhotoViewModel,
                    showSecurity: $showSecurity,
                    open: { profilePath.push($0) }
                )
                .navigationDestination(for: ShumProfileRoute.self) { route in
                    profileDestination(route)
                }
            }
            .modifier(ShumPeerPhotoPresentationHost())
            .toolbar(
                showSecurity || profilePath.last?.hidesTabBar == true ? .hidden : .visible,
                for: .tabBar
            )
            .tabItem { tabLabel("Профиль".localized, image: "PixelProfile", tab: 2) }.tag(2)
        }
        .tint(palette.accent)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !chat.isReady {
                Button { coordinator.retryMessaging() } label: {
                    Label("Не удалось открыть сообщения. Повторить".localized, systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.footnote).padding(12).frame(maxWidth: .infinity).background(.thinMaterial)
                }
            }
        }
        .shumSheet(isPresented: $showContacts) {
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
        }
        .shumSheet(item: $coordinator.invitation) { card in
            ShumContactConfirmation(
                card: chat.currentProfileCard(card),
                imageData: chat.profile(for: card.peerID)?.avatar,
                isExistingContact: isExistingContact(card)
            ) {
                openScannedContact(card)
            }
        }
        .alert("Shum", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
            Button("Понятно".localized) { chat.error = nil }
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
            else if arguments.contains("-ShumPreviewChat"),
                    let peer = chat.chatPeers.first ?? chat.messages.first.map({
                        ShumPeer(id: $0.peerID, name: "Аня", lastConnected: Date())
                    }) {
                chatsPath = [.conversation(peer)]
            }
        }
        #endif
    }

    private func tabLabel(_ title: String, image name: String, tab: Int, badge: Int = 0) -> some View {
        Label {
            Text(title)
        } icon: {
            if let image = UIImage(named: name) {
                // A visibility change refreshes the tab bar. Bake the theme
                // color into the pixel art so UIKit cannot flash its gray tint.
                Image(uiImage: Self.tabIcon(
                    image.withTintColor(tabIconColor(isSelected: selectedTab == tab),
                                        renderingMode: .alwaysOriginal),
                    badge: badge
                ))
            } else {
                Image(name)
            }
        }
        .accessibilityValue(badge > 0 ? "\(badge)" : "")
    }

    /// The icon with its unread count drawn in. A system badge is a separate
    /// layer that slips under the icon when the tab bar swaps the recolored
    /// icon on a tab change or a press; drawn in, it stays on top.
    private static func tabIcon(_ icon: UIImage, badge: Int) -> UIImage {
        guard badge > 0 else { return icon }
        let text = badge > 99 ? "99+" : "\(badge)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: UIColor.white,
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let height: CGFloat = 16
        let width = max(height, ceil(textSize.width) + 8)
        // Equal room on every side keeps the icon where it was, centered
        // under its title; the badge sits up in the top-right corner of it.
        let side: CGFloat = 9
        let lift: CGFloat = 7
        let size = CGSize(width: icon.size.width + side * 2, height: icon.size.height + lift * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = icon.scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            icon.draw(at: CGPoint(x: side, y: lift))
            let frame = CGRect(x: size.width - width, y: 0, width: width, height: height)
            UIColor.systemRed.setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: height / 2).fill()
            (text as NSString).draw(
                at: CGPoint(x: frame.midX - textSize.width / 2, y: frame.midY - textSize.height / 2),
                withAttributes: attributes
            )
        }
        return image.withRenderingMode(.alwaysOriginal)
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
        if peerID == ShumPublicChatView.pixelSeed {
            selectedTab = 1
            chatsPath = [.publicChat]
            coordinator.clearChatNotificationPeerID()
            return
        }
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
        guard let peer = chat.addContact(card, source: "link") else { return }
        coordinator.invitation = nil
        selectedTab = 1
        // An explicitly accepted invitation can replace a chat already open
        // from a notification/deep link; it is not another tap on its source list.
        chatsPath = [.conversation(peer)]
    }

}
