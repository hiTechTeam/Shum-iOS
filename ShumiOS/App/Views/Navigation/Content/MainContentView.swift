import SwiftUI

struct MainContentView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var chat: ShumChatRuntime
    @ObservedObject var profilePhotoViewModel: ProfilePhotoViewModel
    @State private var selectedTab = 1
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { ShumPeopleView() }
                .tabItem { Label("Люди", image: "PixelPeople") }.tag(0)
            NavigationStack { ShumChatsView() }
                .tabItem { Label("Чаты", image: "PixelChats") }.badge(chat.unreadCount).tag(1)
            NavigationStack {
                ProfileOverviewView(authCodeViewModel: coordinator.authCodeViewModel, photoViewModel: profilePhotoViewModel)
                    .navigationTitle("Профиль").navigationBarTitleDisplayMode(.inline)
            }.tabItem { Label("Профиль", image: "PixelProfile") }.tag(2)
        }
        .tint(.accentColor)
        .onReceive(NotificationCenter.default.publisher(for: .shumOpenChats)) { _ in selectedTab = 1 }
    }
}
