import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var chat: SpotchatRuntime
    @ObservedObject var profilePhotoViewModel: ProfilePhotoViewModel
    @State private var selectedTab = 1
    @State private var peoplePath: [SpotchatPeer] = []
    @State private var chatsPath: [SpotchatUIRoute] = []
    @State private var showContacts = false
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $peoplePath) {
                ShumPeopleScreen(runtime: chat) { peoplePath.append($0) }
                    .navigationDestination(for: SpotchatPeer.self) { peer in
                        SpotchatConversationView(runtime: chat, peer: peer).toolbar(.hidden, for: .tabBar)
                    }
            }.tabItem { Label("Люди", image: "PixelPeople") }.tag(0)
            NavigationStack(path: $chatsPath) {
                SpotchatChatsUI(runtime: chat) { route in
                    if case .newChat = route { showContacts = true }
                    else { chatsPath.append(route) }
                }
                .navigationDestination(for: SpotchatUIRoute.self) { route in
                    SpotchatDestinationUI(runtime: chat, route: route) { chatsPath.append($0) }
                }
            }.tabItem { Label("Чаты", image: "PixelChats") }
                .badge(chat.chatPeers.reduce(0) { $0 + chat.unreadCount(for: $1.id) }).tag(1)
            NavigationStack {
                ProfileOverviewView(authCodeViewModel: coordinator.authCodeViewModel, photoViewModel: profilePhotoViewModel)
                    .navigationTitle("Профиль").navigationBarTitleDisplayMode(.inline)
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
            SpotchatContactsView(runtime: chat) { peer in
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
            if ProcessInfo.processInfo.arguments.contains("-ShumPreviewChat"), let peer = chat.chatPeers.first { chatsPath = [.conversation(peer)] }
        }
        #endif
    }
}

struct ShumPeopleScreen: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var runtime: SpotchatRuntime
    let select: (SpotchatPeer) -> Void
    @State private var selectedPeer: SpotchatPeer?
    var body: some View {
        List {
            if !coordinator.isScaning {
                Section {
                    Text("Включите видимость, чтобы найти людей рядом.").foregroundStyle(.secondary)
                    RegistrationPrimaryButton(title: "Найти людей") { coordinator.setScanning(true) }
                }
            } else if runtime.bluetoothState == .unauthorized {
                Section {
                    Text("Разрешите Bluetooth для Shum в настройках iPhone.")
                    Link("Открыть настройки", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
            } else if runtime.bluetoothState == .poweredOff {
                Text("Включите Bluetooth на iPhone, чтобы увидеть людей рядом.").foregroundStyle(.secondary)
            } else if runtime.peers.isEmpty {
                VStack(spacing: 16) {
                    Image.shumLogo.resizable().scaledToFit().frame(width: 58, height: 58)
                    Text("Кто рядом?").font(.title2.bold())
                    Text("Откройте Shum на другом iPhone.\nОн появится здесь, когда окажется поблизости.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 54).listRowBackground(Color.clear)
            }
            ForEach(runtime.peers) { peer in
                Button { selectedPeer = peer } label: {
                    HStack(spacing: 14) {
                        SpotchatAvatar(name: runtime.displayName(peer), size: 64, nearby: true, imageData: runtime.profile(for: peer.id)?.avatar)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(runtime.displayName(peer)).font(.headline)
                            Text(runtime.profile(for: peer.id)?.bio ?? "Рядом с вами").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }.padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .contextMenu { Button("Написать") { select(peer) } }
            }
        }
        .listStyle(.insetGrouped).navigationTitle("Люди")
        .sheet(item: $selectedPeer) { peer in
            ShumPeerCard(runtime: runtime, peer: peer) { selectedPeer = nil; select(peer) }
        }
    }
}

struct ShumPeerCard: View {
    @ObservedObject var runtime: SpotchatRuntime
    let peer: SpotchatPeer
    let write: () -> Void
    @State private var showPhoto = false
    var body: some View {
        VStack(spacing: 20) {
            Button { showPhoto = runtime.profile(for: peer.id)?.avatar != nil } label: {
                SpotchatAvatar(name: runtime.displayName(peer), size: 144, nearby: true, imageData: runtime.profile(for: peer.id)?.avatar)
            }.buttonStyle(.plain).accessibilityLabel("Посмотреть фото собеседника")
            Text(runtime.displayName(peer)).font(.title.bold())
            if let bio = runtime.profile(for: peer.id)?.bio, !bio.isEmpty { Text(bio).multilineTextAlignment(.center).foregroundStyle(.secondary) }
            RegistrationPrimaryButton(title: "Написать", action: write)
            if let card = runtime.permanent?.card(for: peer.id) { SpotchatContactActionsMenu(runtime: runtime, card: card) }
        }.padding(24).presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .fullScreenCover(isPresented: $showPhoto) {
            if let data = runtime.profile(for: peer.id)?.avatar { SpotchatPhotoViewer(data: data) }
        }
    }
}
