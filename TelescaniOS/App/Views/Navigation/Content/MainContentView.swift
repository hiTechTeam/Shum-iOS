import SwiftUI
import UIKit

struct MainContentView: View {

    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @State private var selectedTab: SelectedTab = .near
    @State private var navigationPath: [MainDestination] = []
    @State private var showScanAlert = false
    @State private var showBluetoothAlert = false

    var body: some View {
        ZStack {
            NavigationStack(path: $navigationPath) {
                ZStack {
                    Color.tsBackground
                        .ignoresSafeArea()

                    contentPager
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .modifier(NativeTopScrollEdgeEffect())
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
            .disabled(showScanAlert)

            if showScanAlert {
                ScanningQuickAlert(
                    isScanning: scanningBinding,
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
            if !isScanning, selectedTab == .near {
                selectedTab = .met
            }
        }
        .alert(Inc.Alerts.turnOnBLE.localized, isPresented: $showBluetoothAlert) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
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

    private var contentPager: some View {
        TabView(selection: pageSelection) {
            PeopleView()
                .tag(SelectedTab.near)

            EncounterHistoryView()
                .tag(SelectedTab.met)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var pageSelection: Binding<SelectedTab> {
        Binding(
            get: { selectedTab },
            set: selectTab
        )
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

    private var scanningBinding: Binding<Bool> {
        Binding(
            get: { coordinator.isScaning },
            set: { isScanning in
                coordinator.setScanning(isScanning)
                UISelectionFeedbackGenerator().selectionChanged()

                guard isScanning else { return }

                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedTab = .near
                    showScanAlert = false
                }

                if !BLEManager.shared.isBluetoothAvailable {
                    DispatchQueue.main.async {
                        showBluetoothAlert = true
                    }
                }
            }
        )
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
            ChatsPlaceholderView()
                .toolbar(.visible, for: .navigationBar)
        }
    }
}

private enum MainDestination: Hashable {
    case settings
    case chats
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
    @State private var dragProgress: CGFloat?
    @State private var dragStartProgress: CGFloat?

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
                    badgeColor: .green,
                    isAvailable: isScanningEnabled
                )

                tabButton(
                    title: Inc.Tabs.metTitle.localized,
                    tab: .met,
                    count: encounterCount,
                    badgeColor: .orange,
                    isAvailable: true
                )
            }
        }
        .padding(barPadding)
        .frame(width: barWidth)
        .modifier(TextTabBarSurface())
        .contentShape(Capsule())
        .simultaneousGesture(selectionDragGesture)
        .animation(.spring(response: 0.30, dampingFraction: 0.82), value: selectedTab)
    }

    private var selectionPill: some View {
        SelectedTabSurface()
            .frame(width: tabWidth, height: 44)
            .offset(x: selectionPillOffset)
            .allowsHitTesting(false)
    }

    private var selectionPillOffset: CGFloat {
        effectiveProgress * tabWidth
    }

    private var effectiveProgress: CGFloat {
        dragProgress ?? progress(for: selectedTab)
    }

    private var selectionDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }

                let start = dragStartProgress ?? progress(for: selectedTab)
                if dragStartProgress == nil {
                    dragStartProgress = start
                }
                dragProgress = min(
                    max(start + value.translation.width / tabWidth, 0),
                    1
                )
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    resetDragPosition()
                    return
                }

                let start = dragStartProgress ?? progress(for: selectedTab)
                let projectedProgress = min(
                    max(start + value.predictedEndTranslation.width / tabWidth, 0),
                    1
                )
                let requestedTab: SelectedTab = projectedProgress < 0.5
                    ? .near
                    : .met
                let resolvedTab = requestedTab == .near && !isScanningEnabled
                    ? selectedTab
                    : requestedTab

                select(requestedTab)
                dragStartProgress = nil

                withAnimation(
                    .spring(response: 0.30, dampingFraction: 0.84)
                ) {
                    dragProgress = progress(for: resolvedTab)
                } completion: {
                    dragProgress = nil
                }
            }
    }

    private func progress(for tab: SelectedTab) -> CGFloat {
        tab == .near ? 0 : 1
    }

    private func resetDragPosition() {
        dragStartProgress = nil
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            dragProgress = progress(for: selectedTab)
        } completion: {
            dragProgress = nil
        }
    }

    private func tabButton(
        title: String,
        tab: SelectedTab,
        count: Int,
        badgeColor: Color,
        isAvailable: Bool
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
                        .background(
                            isAvailable ? badgeColor : Color.gray,
                            in: Capsule()
                        )
                        .transition(.scale.combined(with: .opacity))
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
            .background {
                DisabledTabSurface(isVisible: !isAvailable)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityValue(count > 0 ? count.formatted() : "")
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
            GlassEffectContainer(spacing: 0) {
                content
                    .glassEffect(.regular.interactive(), in: Capsule())
            }
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

private struct NativeTopScrollEdgeEffect: ViewModifier {
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
    @Binding var isScanning: Bool
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    Text(Inc.Scanning.justTurnScaning.localized)
                        .font(.headline)

                    Text(Inc.Scanning.scanAlertText.localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 22)
                .padding(.top, 22)
                .padding(.bottom, 18)

                Divider()

                Toggle(
                    Inc.Scanning.scanning.localized,
                    isOn: $isScanning
                )
                .font(.body.weight(.medium))
                .toggleStyle(.switch)
                .tint(.green)
                .padding(.horizontal, 20)
                .frame(height: 56)

                Divider()

                Button(Inc.Common.okey.localized, action: dismiss)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
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
    var body: some View {
        Group {
            if #available(iOS 26.0, *) {
                Color.clear
                    .glassEffect(.regular.interactive(), in: Capsule())
            } else {
                Capsule()
                    .fill(Color(uiColor: .secondarySystemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            }
        }
    }
}

private struct DisabledTabSurface: View {
    let isVisible: Bool

    @ViewBuilder
    var body: some View {
        if isVisible {
            Capsule()
                .fill(Color(uiColor: .systemGray4).opacity(0.42))
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
