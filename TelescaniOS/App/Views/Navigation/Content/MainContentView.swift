import SwiftUI
import UIKit

struct MainContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var peopleViewModel: PeopleViewModel
    @ObservedObject var profilePhotoViewModel: ProfilePhotoViewModel

    @State private var selectedMainTab: MainTab = .nearby
    @State private var nearbyNavigationID = UUID()

    var body: some View {
        TabView(selection: mainTabBinding) {
            nearbyTab
                .tabItem {
                    nearbyTabItem
                }
                .badge(
                    coordinator.isScaning
                        ? peopleViewModel.visibleUsers.count
                        : 0
                )
                .tag(MainTab.nearby)

            profileTab
                .tabItem {
                    ProfileTabLabel(
                        photoViewModel: profilePhotoViewModel
                    )
                }
                .badge(peopleViewModel.unviewedEncounterCount)
                .tag(MainTab.profile)
        }
        .tint(Color(uiColor: .systemBlue))
        .background(
            TabBarBadgeAppearanceConfigurator(
                colorScheme: colorScheme,
                selectedTab: selectedMainTab,
                isScanning: coordinator.isScaning
            )
        )
        .onChange(of: coordinator.nearbyNotificationNavigationRequest) {
            _, _ in
            selectedMainTab = .nearby
            nearbyNavigationID = UUID()
        }
    }

    private var nearbyTab: some View {
        NavigationStack {
            PeopleView()
            .navigationTitle(Inc.Common.nearby.localized)
            .navigationBarTitleDisplayMode(.inline)
        }
        .id(nearbyNavigationID)
    }

    private var mainTabBinding: Binding<MainTab> {
        Binding(
            get: { selectedMainTab },
            set: selectMainTab
        )
    }

    private var profileTab: some View {
        NavigationStack {
            ProfileOverviewView(
                authCodeViewModel: coordinator.authCodeViewModel,
                photoViewModel: coordinator.profilePhotoViewModel
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                coordinator.authCodeViewModel.restoreLocalProfile()
            }
        }
    }

    @ViewBuilder
    private var nearbyTabItem: some View {
        if coordinator.isScaning {
            Label(
                Inc.Common.nearby.localized,
                systemImage: "person.2.fill"
            )
        } else {
            Image(systemName: "eye.slash")
                .accessibilityLabel(Inc.Common.nearby.localized)
        }
    }

    private func selectMainTab(_ tab: MainTab) {
        guard tab != selectedMainTab else { return }
        selectedMainTab = tab
    }

}

private struct ProfileTabLabel: View {
    @ObservedObject var photoViewModel: ProfilePhotoViewModel

    var body: some View {
        Label {
            Text(Inc.Tabs.profile.localized)
        } icon: {
            if let image = photoViewModel.uiImage {
                Image(uiImage: image.tabBarAvatarImage())
                    .renderingMode(.original)
            } else {
                Image(systemName: "person.circle.fill")
            }
        }
    }
}

private extension UIImage {
    func tabBarAvatarImage(diameter: CGFloat = 28) -> UIImage {
        let bounds = CGRect(
            origin: .zero,
            size: CGSize(width: diameter, height: diameter)
        )
        let imageScale = max(diameter / size.width, diameter / size.height)
        let drawSize = CGSize(
            width: size.width * imageScale,
            height: size.height * imageScale
        )
        let drawRect = CGRect(
            x: (diameter - drawSize.width) / 2,
            y: (diameter - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false

        let avatar = UIGraphicsImageRenderer(
            size: bounds.size,
            format: format
        ).image { _ in
            UIBezierPath(ovalIn: bounds).addClip()
            draw(in: drawRect)
        }
        return avatar.withRenderingMode(.alwaysOriginal)
    }
}

private enum MainTab: Hashable {
    case nearby
    case profile
}

private struct TabBarBadgeAppearanceConfigurator:
    UIViewControllerRepresentable {
    let colorScheme: ColorScheme
    let selectedTab: MainTab
    let isScanning: Bool

    func makeUIViewController(
        context: Context
    ) -> TabBarBadgeAppearanceController {
        TabBarBadgeAppearanceController(
            colorScheme: colorScheme,
            selectedTab: selectedTab,
            isScanning: isScanning
        )
    }

    func updateUIViewController(
        _ uiViewController: TabBarBadgeAppearanceController,
        context: Context
    ) {
        uiViewController.update(
            colorScheme: colorScheme,
            selectedTab: selectedTab,
            isScanning: isScanning
        )
    }
}

private final class TabBarBadgeAppearanceController: UIViewController {
    private var colorScheme: ColorScheme
    private var selectedTab: MainTab
    private var isScanning: Bool
    private weak var configuredTabBar: UITabBar?
    private var configuredColorScheme: ColorScheme?
    private var configuredSelectedTab: MainTab?
    private var configuredIsScanning: Bool?

    init(
        colorScheme: ColorScheme,
        selectedTab: MainTab,
        isScanning: Bool
    ) {
        self.colorScheme = colorScheme
        self.selectedTab = selectedTab
        self.isScanning = isScanning
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

    func update(
        colorScheme: ColorScheme,
        selectedTab: MainTab,
        isScanning: Bool
    ) {
        guard self.colorScheme != colorScheme
                || self.selectedTab != selectedTab
                || self.isScanning != isScanning else {
            return
        }

        self.colorScheme = colorScheme
        self.selectedTab = selectedTab
        self.isScanning = isScanning
        applyAppearanceWhenAvailable()
    }

    func applyAppearanceWhenAvailable() {
        DispatchQueue.main.async { [weak self] in
            self?.applyAppearance()
        }
    }

    private func applyAppearance() {
        guard let tabBar = enclosingTabBarController?.tabBar,
              let items = tabBar.items,
              items.count >= 2 else {
            return
        }

        let peopleItem = items[0]
        let profileItem = items[1]
        peopleItem.title = isScanning ? Inc.Common.nearby.localized : nil
        peopleItem.accessibilityLabel = Inc.Common.nearby.localized

        if configuredTabBar === tabBar,
           configuredColorScheme == colorScheme,
           configuredSelectedTab == selectedTab,
           configuredIsScanning == isScanning {
            return
        }

        let inactiveBadgeTextColor: UIColor = colorScheme == .dark
            ? .white
            : .black

        configurePeopleBadge(
            for: peopleItem,
            isSelected: selectedTab == .nearby,
            inactiveTextColor: inactiveBadgeTextColor
        )
        configureProfileBadge(
            for: profileItem,
            isSelected: selectedTab == .profile,
            inactiveTextColor: inactiveBadgeTextColor
        )
        configuredTabBar = tabBar
        configuredColorScheme = colorScheme
        configuredSelectedTab = selectedTab
        configuredIsScanning = isScanning
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

    private func configureProfileBadge(
        for item: UITabBarItem,
        isSelected: Bool,
        inactiveTextColor: UIColor
    ) {
        configureBadge(
            for: item,
            backgroundColor: isSelected ? .systemOrange : .systemGray,
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
