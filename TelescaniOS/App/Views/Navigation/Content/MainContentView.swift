import SwiftUI
import UIKit

struct MainContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @StateObject private var profilePhotoViewModel = ProfilePhotoViewModel()
    @State private var selectedMainTab: MainTab = .nearby

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
                    Label {
                        Text(Inc.Tabs.me.localized)
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
    }

    private var nearbyTab: some View {
        NavigationStack {
            PeopleView()
            .navigationTitle(Inc.Common.nearby.localized)
            .navigationBarTitleDisplayMode(.inline)
        }
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
                photoViewModel: profilePhotoViewModel
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
        Label(
            Inc.Tabs.people.localized,
            systemImage: coordinator.isScaning
                ? "person.2.fill"
                : "eye.slash"
        )
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
        selectedMainTab = tab
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
        uiViewController.update(
            colorScheme: colorScheme,
            selectedTab: selectedTab
        )
    }
}

private final class TabBarBadgeAppearanceController: UIViewController {
    private var colorScheme: ColorScheme
    private var selectedTab: MainTab
    private weak var configuredTabBar: UITabBar?
    private var configuredColorScheme: ColorScheme?
    private var configuredSelectedTab: MainTab?

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

    func update(colorScheme: ColorScheme, selectedTab: MainTab) {
        guard self.colorScheme != colorScheme
                || self.selectedTab != selectedTab else {
            return
        }

        self.colorScheme = colorScheme
        self.selectedTab = selectedTab
        applyAppearanceWhenAvailable()
    }

    func applyAppearanceWhenAvailable() {
        DispatchQueue.main.async { [weak self] in
            self?.applyAppearance()
        }
    }

    private func applyAppearance() {
        if let configuredTabBar,
           configuredColorScheme == colorScheme,
           configuredSelectedTab == selectedTab {
            return
        }

        guard let tabBar = enclosingTabBarController?.tabBar,
              let items = tabBar.items,
              !items.isEmpty else {
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
        configuredTabBar = tabBar
        configuredColorScheme = colorScheme
        configuredSelectedTab = selectedTab
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
