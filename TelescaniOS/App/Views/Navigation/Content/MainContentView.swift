import SwiftUI
import UIKit

struct MainContentView: View {

    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @State private var selectedTab: SelectedTab = .near
    @State private var navigationPath: [MainDestination] = []
    @State private var showScanAlert = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                Color.tsBackground
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    MainHeader(
                        title: headerTitle,
                        openSettings: {
                            navigationPath.append(.settings)
                        },
                        openChats: {
                            navigationPath.append(.chats)
                        }
                    )

                    selectedContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                TextTabBar(
                    selectedTab: selectedTab,
                    nearbyCount: peopleViewModel.visibleUsers.count,
                    encounterCount: peopleViewModel.encounterHistory.count,
                    select: selectTab
                )
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: MainDestination.self) { destination in
                destinationView(for: destination)
            }
        }
        .onAppear {
            if !coordinator.isScaning {
                selectedTab = .met
            }
        }
        .onChange(of: coordinator.isScaning) { _, isScanning in
            if !isScanning, selectedTab == .near {
                selectedTab = .met
            }
        }
        .alert(Inc.Scanning.justTurnScaning.localized, isPresented: $showScanAlert) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
        } message: {
            Text(Inc.Scanning.scanAlertText.localized)
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .near:
            PeopleView()
        case .met:
            EncounterHistoryView()
        case .profile:
            EmptyView()
        }
    }

    private var headerTitle: String {
        switch selectedTab {
        case .near:
            Inc.Tabs.peopleNearby.localized
        case .met:
            Inc.Tabs.metHeader.localized
        case .profile:
            Inc.Tabs.profile.localized
        }
    }

    private func selectTab(_ tab: SelectedTab) {
        guard tab != selectedTab else { return }

        if tab == .near, !coordinator.isScaning {
            showScanAlert = true
            return
        }

        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedTab = tab
        }
    }

    @ViewBuilder
    private func destinationView(for destination: MainDestination) -> some View {
        switch destination {
        case .settings:
            SettingsDestinationView(authVM: coordinator.authCodeViewModel)
                .toolbar(.visible, for: .navigationBar)
        case .chats:
            ChatsPlaceholderView()
                .toolbar(.visible, for: .navigationBar)
        }
    }
}

private enum MainDestination: Hashable {
    case settings
    case chats
}

private struct MainHeader: View {
    let title: String
    let openSettings: () -> Void
    let openChats: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            HeaderButton(
                systemImage: "slider.horizontal.3",
                accessibilityLabel: Inc.Tabs.settings.localized,
                action: openSettings
            )

            Spacer(minLength: 0)

            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
                .contentTransition(.opacity)

            Spacer(minLength: 0)

            HeaderButton(
                systemImage: "bubble.left.and.bubble.right",
                accessibilityLabel: Inc.Tabs.chats.localized,
                tint: Color(uiColor: .systemBlue),
                action: openChats
            )
        }
        .padding(.horizontal, 20)
        .frame(height: 74)
    }
}

private struct HeaderButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct TextTabBar: View {
    let selectedTab: SelectedTab
    let nearbyCount: Int
    let encounterCount: Int
    let select: (SelectedTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            tabButton(
                title: Inc.Tabs.people.localized,
                tab: .near,
                count: nearbyCount,
                badgeColor: .green
            )

            tabButton(
                title: Inc.Tabs.metTitle.localized,
                tab: .met,
                count: encounterCount,
                badgeColor: .orange
            )
        }
        .padding(4)
        .frame(maxWidth: 276)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
    }

    private func tabButton(
        title: String,
        tab: SelectedTab,
        count: Int,
        badgeColor: Color
    ) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            select(tab)
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))

                if count > 0 {
                    Text(count.formatted())
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(badgeColor, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .foregroundStyle(
                isSelected ? Color(uiColor: .systemBlue) : Color.primary
            )
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background {
                if isSelected {
                    Capsule()
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(count > 0 ? count.formatted() : "")
    }
}

private struct SettingsDestinationView: View {
    @ObservedObject var authVM: CodeViewModel

    var body: some View {
        ProfileDataView(authCodeViewModel: authVM)
            .navigationTitle(Inc.Tabs.settings.localized)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                authVM.restoreLocalProfile()
            }
    }
}

private struct ChatsPlaceholderView: View {
    var body: some View {
        ZStack {
            Color.tsBackground
                .ignoresSafeArea()

            ContentUnavailableView(
                Inc.Chats.unavailableTitle.localized,
                systemImage: "bubble.left.and.bubble.right",
                description: Text(Inc.Chats.unavailableMessage.localized)
            )
        }
        .navigationTitle(Inc.Tabs.chats.localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}
