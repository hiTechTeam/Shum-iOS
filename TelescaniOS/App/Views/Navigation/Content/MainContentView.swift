import SwiftUI
import UIKit

struct MainContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @StateObject private var chatStore = ChatUIStore()
    @StateObject private var profilePhotoViewModel = ProfilePhotoViewModel()
    @State private var selectedMainTab: MainTab = .nearby
    @State private var chatsPath: [ChatsDestination] = []
    @State private var showScanAlert = false

    var body: some View {
        TabView(selection: mainTabBinding) {
            nearbyTab
                .tabItem {
                    Label(
                        Inc.Common.nearby.localized,
                        systemImage: "person.2.fill"
                    )
                }
                .badge(
                    coordinator.isScaning
                        ? peopleViewModel.visibleUsers.count
                        : 0
                )
                .tag(MainTab.nearby)

            recentlyMetTab
                .tabItem {
                    Label(
                        Inc.Tabs.metTitle.localized,
                        systemImage: "clock.arrow.circlepath"
                    )
                }
                .badge(peopleViewModel.encounterHistory.count)
                .tag(MainTab.recentlyMet)

            chatsTab
                .tabItem {
                    Label(
                        Inc.Tabs.chats.localized,
                        systemImage: "bubble.left.and.bubble.right"
                    )
                }
                .tag(MainTab.chats)

            profileTab
                .tabItem {
                    Label {
                        Text(Inc.Tabs.profile.localized)
                    } icon: {
                        profileTabIcon
                    }
                }
                .tag(MainTab.profile)
        }
        .tint(Color(uiColor: .systemBlue))
        .background(
            TabBarBadgeAppearanceConfigurator(
                colorScheme: colorScheme,
                selectedTab: selectedMainTab
            )
        )
        .alert(
            Inc.Common.nearby.localized,
            isPresented: $showScanAlert
        ) {
            Button(Inc.Common.okey.localized, role: .cancel) {}
        } message: {
            Text(Inc.Scanning.scanAlertText.localized)
        }
        .onAppear {
            if !coordinator.isScaning {
                selectedMainTab = .recentlyMet
            }
        }
        .onChange(of: coordinator.isScaning) { _, isScanning in
            if !isScanning, selectedMainTab == .nearby {
                selectedMainTab = .recentlyMet
            }
        }
    }

    private var nearbyTab: some View {
        NavigationStack {
            PeopleView { user in
                openChat(with: user, isNearby: true)
            }
            .navigationTitle(Inc.Common.nearby.localized)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var recentlyMetTab: some View {
        NavigationStack {
            EncounterHistoryView { user in
                openChat(with: user, isNearby: false)
            }
            .navigationTitle(Inc.Tabs.metTitle.localized)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var mainTabBinding: Binding<MainTab> {
        Binding(
            get: { selectedMainTab },
            set: selectMainTab
        )
    }

    private var chatsTab: some View {
        NavigationStack(path: $chatsPath) {
            ChatsListView(store: chatStore) { contact in
                chatsPath.append(.conversation(contact))
            }
            .navigationDestination(for: ChatsDestination.self) { destination in
                switch destination {
                case .conversation(let contact):
                    conversationView(for: contact)
                }
            }
        }
    }

    private var profileTab: some View {
        NavigationStack {
            ProfileDataView(
                authCodeViewModel: coordinator.authCodeViewModel,
                photoViewModel: profilePhotoViewModel
            )
            .navigationTitle(profileNavigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                coordinator.authCodeViewModel.restoreLocalProfile()
            }
        }
    }

    private var profileNavigationTitle: String {
        let name = coordinator.authCodeViewModel.tgName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 }
            ?? Inc.Tabs.profile.localized
    }

    @ViewBuilder
    private var profileTabIcon: some View {
        if let image = profilePhotoViewModel.uiImage {
            Image(uiImage: ProfileTabBarIcon.make(from: image))
        } else {
            Image(systemName: "person.crop.circle")
        }
    }

    private func selectMainTab(_ tab: MainTab) {
        guard tab != selectedMainTab else { return }

        if tab == .nearby, !coordinator.isScaning {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            showScanAlert = true
            return
        }

        selectedMainTab = tab
    }

    private func conversationView(
        for contact: ChatContact
    ) -> some View {
        ChatConversationView(
            contact: contact,
            store: chatStore,
            isNearby: peopleViewModel.visibleUsers.contains {
                $0.id == contact.id
            },
            lastMetAt: lastMetAt(for: contact)
        )
        .toolbar(.hidden, for: .tabBar)
    }

    private func openChat(with user: NearbyUser, isNearby: Bool) {
        let encounterDate = peopleViewModel.encounterHistory
            .first(where: { $0.id == user.id })?
            .lastSeen
        let contact = ChatContact(
            user: user,
            isNearby: isNearby,
            lastMetAt: isNearby ? .now : encounterDate ?? .now
        )
        chatsPath.removeAll()
        selectedMainTab = .chats

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            withAnimation {
                chatsPath.append(.conversation(contact))
            }
        }
    }

    private func lastMetAt(for contact: ChatContact) -> Date {
        peopleViewModel.encounterHistory
            .first(where: { $0.id == contact.id })?
            .lastSeen
            ?? contact.lastMetAt
    }
}

private enum MainTab: Hashable {
    case nearby
    case recentlyMet
    case chats
    case profile
}

private enum ChatsDestination: Hashable {
    case conversation(ChatContact)
}

private struct TabBarBadgeAppearanceConfigurator:
    UIViewControllerRepresentable {
    let colorScheme: ColorScheme
    let selectedTab: MainTab

    func makeUIViewController(
        context: Context
    ) -> TabBarBadgeAppearanceController {
        TabBarBadgeAppearanceController(
            colorScheme: colorScheme,
            selectedTab: selectedTab
        )
    }

    func updateUIViewController(
        _ uiViewController: TabBarBadgeAppearanceController,
        context: Context
    ) {
        uiViewController.colorScheme = colorScheme
        uiViewController.selectedTab = selectedTab
        uiViewController.applyAppearanceWhenAvailable()
    }
}

private final class TabBarBadgeAppearanceController: UIViewController {
    var colorScheme: ColorScheme
    var selectedTab: MainTab

    init(colorScheme: ColorScheme, selectedTab: MainTab) {
        self.colorScheme = colorScheme
        self.selectedTab = selectedTab
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        self.view = view
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        applyAppearanceWhenAvailable()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyAppearance()
    }

    func applyAppearanceWhenAvailable() {
        DispatchQueue.main.async { [weak self] in
            self?.applyAppearance()
        }
    }

    private func applyAppearance() {
        guard let items = enclosingTabBarController?.tabBar.items,
              items.count >= 3 else {
            return
        }

        let inactiveBadgeTextColor: UIColor = colorScheme == .dark
            ? .white
            : .black

        configurePeopleBadge(
            for: items[0],
            isSelected: selectedTab == .nearby,
            inactiveTextColor: inactiveBadgeTextColor
        )
        configurePeopleBadge(
            for: items[1],
            isSelected: selectedTab == .recentlyMet,
            inactiveTextColor: inactiveBadgeTextColor
        )
        configureBadge(
            for: items[2],
            backgroundColor: .systemRed,
            textColor: .white
        )
    }

    private func configurePeopleBadge(
        for item: UITabBarItem,
        isSelected: Bool,
        inactiveTextColor: UIColor
    ) {
        configureBadge(
            for: item,
            backgroundColor: isSelected ? .systemBlue : .systemGray,
            textColor: isSelected ? .white : inactiveTextColor
        )
    }

    private var enclosingTabBarController: UITabBarController? {
        var current: UIViewController? = self

        while let viewController = current {
            if let tabBarController = viewController as? UITabBarController {
                return tabBarController
            }
            current = viewController.parent
        }

        return findTabBarController(in: view.window?.rootViewController)
    }

    private func findTabBarController(
        in viewController: UIViewController?
    ) -> UITabBarController? {
        guard let viewController else { return nil }
        if let tabBarController = viewController as? UITabBarController {
            return tabBarController
        }

        for child in viewController.children {
            if let tabBarController = findTabBarController(in: child) {
                return tabBarController
            }
        }

        return nil
    }

    private func configureBadge(
        for item: UITabBarItem,
        backgroundColor: UIColor,
        textColor: UIColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: textColor
        ]

        item.badgeColor = backgroundColor
        item.setBadgeTextAttributes(attributes, for: .normal)
        item.setBadgeTextAttributes(attributes, for: .selected)
    }
}

private enum ProfileTabBarIcon {
    private static let canvasSize = CGSize(width: 25, height: 25)

    static func make(from source: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(
            size: canvasSize,
            format: format
        )
        let image = renderer.image { _ in
            let bounds = CGRect(origin: .zero, size: canvasSize)
            UIBezierPath(ovalIn: bounds).addClip()

            let sourceSize = source.size
            let scale = max(
                canvasSize.width / sourceSize.width,
                canvasSize.height / sourceSize.height
            )
            let drawSize = CGSize(
                width: sourceSize.width * scale,
                height: sourceSize.height * scale
            )
            source.draw(
                in: CGRect(
                    x: (canvasSize.width - drawSize.width) / 2,
                    y: (canvasSize.height - drawSize.height) / 2,
                    width: drawSize.width,
                    height: drawSize.height
                )
            )
        }

        return image.withRenderingMode(.alwaysOriginal)
    }
}
