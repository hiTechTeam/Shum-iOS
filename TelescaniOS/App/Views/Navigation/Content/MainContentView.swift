import SwiftUI
import UIKit

struct MainContentView: View {

    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @StateObject private var chatStore = ChatUIStore()
    @State private var selectedTab: SelectedTab = .near
    @State private var navigationPath: [MainDestination] = []
    @State private var showScanAlert = false

    var body: some View {
        ZStack {
            NavigationStack(path: $navigationPath) {
                ZStack {
                    Color.tsBackground
                        .ignoresSafeArea()

                    selectedContent
                        .id(selectedTab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(NativeTopScrollEdgeEffect())
                        .transition(.opacity)
                }
                .navigationTitle(headerTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if navigationPath.isEmpty {
                        rootToolbar
                    }
                }
                .modifier(
                    BottomTabBarLayout(
                        tabBar: TextTabBar(
                            selectedTab: selectedTab,
                            nearbyCount: peopleViewModel.visibleUsers.count,
                            encounterCount: peopleViewModel.encounterHistory.count,
                            isScanningEnabled: coordinator.isScaning,
                            select: selectTab
                        )
                    )
                )
                .navigationDestination(for: MainDestination.self) { destination in
                    destinationView(for: destination)
                }
            }
            .allowsHitTesting(!showScanAlert)

            if showScanAlert {
                ScanningQuickAlert(
                    dismiss: dismissScanAlert
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showScanAlert)
        .onAppear {
            if !coordinator.isScaning {
                selectedTab = .met
            }
        }
        .onChange(of: coordinator.isScaning) { _, isScanning in
            if navigationPath.isEmpty,
               !isScanning,
               selectedTab == .near {
                selectedTab = .met
            }
        }
        .onChange(of: navigationPath) { _, path in
            guard path.isEmpty,
                  !coordinator.isScaning,
                  selectedTab == .near else {
                return
            }
            selectedTab = .met
        }
    }

    @ToolbarContentBuilder
    private var rootToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HeaderButton(
                systemImage: "slider.horizontal.3",
                accessibilityLabel: Inc.Tabs.settings.localized
            ) {
                navigationPath.append(.settings)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            HeaderButton(
                systemImage: "bubble.left.and.bubble.right",
                accessibilityLabel: Inc.Tabs.chats.localized,
                tint: Color(uiColor: .systemBlue)
            ) {
                navigationPath.append(.chats)
            }
        }
    }

    @ViewBuilder
    private var selectedContent: some View {
        switch selectedTab {
        case .near:
            PeopleView { user in
                openChat(with: user, isNearby: true)
            }
        case .met:
            EncounterHistoryView { user in
                openChat(with: user, isNearby: false)
            }
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
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            withAnimation {
                showScanAlert = true
            }
            return
        }

        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedTab = tab
        }
    }

    private func dismissScanAlert() {
        withAnimation {
            showScanAlert = false
        }
    }

    @ViewBuilder
    private func destinationView(for destination: MainDestination) -> some View {
        switch destination {
        case .settings:
            SettingsDestinationView(authVM: coordinator.authCodeViewModel)
                .toolbar(.visible, for: .navigationBar)
        case .chats:
            ChatsListView(
                store: chatStore
            ) { contact in
                navigationPath.append(.conversation(contact))
            }
                .toolbar(.visible, for: .navigationBar)
        case .conversation(let contact):
            ChatConversationView(
                contact: contact,
                store: chatStore,
                isNearby: peopleViewModel.visibleUsers.contains {
                    $0.id == contact.id
                },
                lastMetAt: lastMetAt(for: contact)
            )
                .toolbar(.visible, for: .navigationBar)
        }
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
        navigationPath.append(.conversation(contact))
    }

    private func lastMetAt(for contact: ChatContact) -> Date {
        peopleViewModel.encounterHistory
            .first(where: { $0.id == contact.id })?
            .lastSeen
            ?? contact.lastMetAt
    }
}

private enum MainDestination: Hashable {
    case settings
    case chats
    case conversation(ChatContact)
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
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct TextTabBar: View {
    @Namespace private var glassNamespace

    let selectedTab: SelectedTab
    let nearbyCount: Int
    let encounterCount: Int
    let isScanningEnabled: Bool
    let select: (SelectedTab) -> Void

    private let barWidth: CGFloat = 276
    private let barPadding: CGFloat = 4

    private var tabWidth: CGFloat {
        (barWidth - (barPadding * 2)) / 2
    }

    var body: some View {
        ZStack(alignment: .leading) {
            selectionPill

            HStack(spacing: 0) {
                tabButton(
                    title: Inc.Tabs.people.localized,
                    tab: .near,
                    count: nearbyCount,
                    isAvailable: isScanningEnabled
                )

                tabButton(
                    title: Inc.Tabs.metTitle.localized,
                    tab: .met,
                    count: encounterCount,
                    isAvailable: true
                )
            }
        }
        .padding(barPadding)
        .frame(width: barWidth)
        .modifier(TextTabBarSurface())
        .contentShape(Capsule())
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: selectedTab)
    }

    private var selectionPill: some View {
        SelectedTabSurface(namespace: glassNamespace)
            .frame(width: tabWidth, height: 44)
            .offset(x: selectionPillOffset)
            .allowsHitTesting(false)
    }

    private var selectionPillOffset: CGFloat {
        progress(for: selectedTab) * tabWidth
    }

    private func progress(for tab: SelectedTab) -> CGFloat {
        tab == .near ? 0 : 1
    }

    private func tabButton(
        title: String,
        tab: SelectedTab,
        count: Int,
        isAvailable: Bool
    ) -> some View {
        let isSelected = selectedTab == tab

        return Button {
            select(tab)
        } label: {
            HStack(spacing: 7) {
                if isAvailable {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))

                    if count > 0 {
                        Text(count.formatted())
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(
                                isSelected
                                    ? Color(uiColor: .systemBlue)
                                    : Color.gray,
                                in: Capsule()
                            )
                            .transition(.scale.combined(with: .opacity))
                    }
                } else {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 17, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(
                tabForegroundColor(
                    isSelected: isSelected,
                    isAvailable: isAvailable
                )
            )
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(
            isAvailable && count > 0 ? count.formatted() : ""
        )
        .accessibilityHint(
            isAvailable ? "" : Inc.Scanning.justTurnScaning.localized
        )
    }

    private func tabForegroundColor(
        isSelected: Bool,
        isAvailable: Bool
    ) -> Color {
        guard isAvailable else { return Color(uiColor: .systemGray) }
        return isSelected ? Color(uiColor: .systemBlue) : Color.primary
    }
}

private struct TextTabBarSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .glassEffect(.regular.interactive(), in: Capsule())
                .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        }
    }
}

private struct BottomTabBarLayout<TabBar: View>: ViewModifier {
    let tabBar: TabBar

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .overlay(alignment: .bottom) {
                    tabBar
                        .padding(.horizontal, 28)
                        .safeAreaPadding(.bottom, 6)
                }
        } else {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    tabBar
                        .padding(.horizontal, 28)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                }
        }
    }
}

struct NativeTopScrollEdgeEffect: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

private struct ScanningQuickAlert: View {
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(Color(uiColor: .systemGray))

                    Text(Inc.Scanning.scanAlertText.localized)
                        .font(.body)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 18)

                Divider()

                Button(action: dismiss) {
                    Text(Inc.Common.okey.localized)
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: 50)
            }
            .frame(maxWidth: 320)
            .modifier(ScanningAlertSurface())
            .padding(.horizontal, 28)
        }
        .accessibilityAddTraits(.isModal)
    }
}

private struct ScanningAlertSurface: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 26))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
        }
    }
}

private struct SelectedTabSurface: View {
    let namespace: Namespace.ID

    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: 0) {
                    Capsule()
                        .fill(Color.primary.opacity(0.001))
                        .glassEffect(
                            .regular
                                .tint(Color.primary.opacity(0.08))
                                .interactive(),
                            in: Capsule()
                        )
                        .glassEffectID("selected-tab", in: namespace)
                }
            } else {
                Capsule()
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
        }
    }
}

private struct SettingsDestinationView: View {
    @ObservedObject var authVM: CodeViewModel

    var body: some View {
        ProfileDataView(authCodeViewModel: authVM)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                authVM.restoreLocalProfile()
            }
    }

    private var navigationTitle: String {
        let name = authVM.tgName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.flatMap { $0.isEmpty ? nil : $0 }
            ?? Inc.Tabs.settings.localized
    }
}
