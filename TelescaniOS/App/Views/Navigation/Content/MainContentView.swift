import SwiftUI
import UIKit

struct MainContentView: View {
    
    @EnvironmentObject var coordinator: AppCoordinator
    
    @State private var selectedTab: SelectedTab = .near
    @State private var previousTab: SelectedTab = .near
    @State private var showScanAlert = false
    
    var body: some View {
        TabView(selection: $selectedTab) {
            People(authVM: coordinator.authCodeViewModel)
            EncounterHistoryTab()
            Profile(authVM: coordinator.authCodeViewModel)
        }
        .background {
            TabBarBadgeColorConfigurator(
                nearbyTitle: Inc.Tabs.people.localized,
                encountersTitle: Inc.Tabs.metTitle.localized
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .onAppear {
            if coordinator.isScaning == false {
                selectedTab = .profile
                previousTab = .profile
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            if newValue == .near && coordinator.isScaning == false {
                showScanAlert = true
                selectedTab = previousTab
            } else {
                previousTab = newValue
            }
        }
        .alert(Inc.Scanning.justTurnScaning.localized, isPresented: $showScanAlert) {
            Button(Inc.Common.okey, role: .cancel) { }
        } message: {
            Text(Inc.Scanning.scanAlertText.localized)
        }
    }
}

private struct TabBarBadgeColorConfigurator: UIViewControllerRepresentable {
    let nearbyTitle: String
    let encountersTitle: String

    func makeUIViewController(context: Context) -> BadgeColorController {
        BadgeColorController(
            nearbyTitle: nearbyTitle,
            encountersTitle: encountersTitle
        )
    }

    func updateUIViewController(
        _ controller: BadgeColorController,
        context: Context
    ) {
        controller.updateTitles(
            nearby: nearbyTitle,
            encounters: encountersTitle
        )
        controller.applyColors()
    }

    final class BadgeColorController: UIViewController {
        private var nearbyTitle: String
        private var encountersTitle: String

        init(nearbyTitle: String, encountersTitle: String) {
            self.nearbyTitle = nearbyTitle
            self.encountersTitle = encountersTitle
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            applyColors()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyColors()
        }

        func updateTitles(nearby: String, encounters: String) {
            nearbyTitle = nearby
            encountersTitle = encounters
        }

        func applyColors() {
            guard let tabBarController = resolvedTabBarController(),
                  let items = tabBarController.tabBar.items,
                  !items.isEmpty else {
                return
            }

            let nearbyItem = items.first { $0.title == nearbyTitle }
                ?? items.first
            let encountersItem = items.first { $0.title == encountersTitle }
                ?? (items.count > 1 ? items[1] : nil)

            nearbyItem?.badgeColor = .systemGreen
            encountersItem?.badgeColor = .systemOrange
        }

        private func resolvedTabBarController() -> UITabBarController? {
            if let tabBarController {
                return tabBarController
            }
            return findTabBarController(in: view.window?.rootViewController)
        }

        private func findTabBarController(
            in controller: UIViewController?
        ) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabBarController = controller as? UITabBarController {
                return tabBarController
            }
            for child in controller.children {
                if let tabBarController = findTabBarController(in: child) {
                    return tabBarController
                }
            }
            if let presented = controller.presentedViewController {
                return findTabBarController(in: presented)
            }
            return nil
        }
    }
}
