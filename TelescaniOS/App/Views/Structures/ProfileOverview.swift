import SwiftUI
import UserNotifications

struct ProfileOverviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @ObservedObject var authCodeViewModel: CodeViewModel
    @ObservedObject private var photoVM: ProfilePhotoViewModel
    @ObservedObject private var savedPeople = SavedPeopleStateStore.shared
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @State private var showScanningSettings = false
    @State private var showInfoSheet = false
    @State private var showLogoutOptions = false
    @State private var showBlockedProfiles = false
    @State private var showSavedProfiles = false
    @State private var showQuickActions = false
    @State private var showLogoutConfirmation = false
    @State private var showLogoutError = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var showPhotoPreview = false
    @State private var isWorking = false
    @State private var notificationAuthorizationStatus:
        UNAuthorizationStatus = .notDetermined

    init(
        authCodeViewModel: CodeViewModel,
        photoViewModel: ProfilePhotoViewModel
    ) {
        self.authCodeViewModel = authCodeViewModel
        self.photoVM = photoViewModel
    }

    private var displayName: String {
        normalized(authCodeViewModel.tgName)
            ?? Inc.Profile.notSpecified.localized
    }

    private var telegramUsername: String? {
        normalized(authCodeViewModel.tgUsername)
    }

    private func openPhotoPreview() {
        guard photoVM.uiImage != nil else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            showPhotoPreview = true
        }
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    profileHeader

                    VStack(spacing: 20) {
                        settingsCard
                        peopleCard
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 30)
                .padding(.bottom, 36)
            }
            .scrollBounceBehavior(.always, axes: .vertical)
            .refreshable { await coordinator.refreshSession() }
        }
        .onChange(of: authCodeViewModel.photoS3URL) { _, value in
            photoVM.loadPhotoFromURL(value)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshNotificationAuthorizationStatus()
                await peopleViewModel.synchronizeBlockedProfiles()
            }
        }
        .task {
            await refreshNotificationAuthorizationStatus()
            await peopleViewModel.synchronizeBlockedProfiles()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                profileMenu

                NavigationLink {
                    ProfileDataView(
                        authCodeViewModel: authCodeViewModel,
                        photoViewModel: photoVM
                    )
                    .navigationTitle(Inc.Tabs.profile.localized)
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Image(systemName: "pencil")
                        .foregroundStyle(.primary)
                }
                .tint(.primary)
                .accessibilityLabel(Inc.Profile.editProfile.localized)
            }
        }
        .sheet(isPresented: $showScanningSettings) {
            ScanningSettingsSheet()
                .environmentObject(coordinator)
                .environmentObject(coordinator.peopleViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showInfoSheet) {
            InfoSheetView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBlockedProfiles) {
            BlockedProfilesView()
                .environmentObject(coordinator.peopleViewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSavedProfiles) {
            SavedProfilesView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showQuickActions) {
            QuickActionsSettingsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $showPhotoPreview) {
            if let image = photoVM.uiImage {
                FullScreenPhotoView(isPresented: $showPhotoPreview) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .alert(
            Inc.Profile.accountActionsTitle.localized,
            isPresented: $showLogoutOptions
        ) {
            Button(Inc.Profile.logoutCurrent.localized, role: .destructive) {
                DispatchQueue.main.async {
                    showLogoutConfirmation = true
                }
            }
            Button(Inc.Profile.deleteAccount.localized, role: .destructive) {
                DispatchQueue.main.async {
                    showDeleteConfirmation = true
                }
            }
            Button(Inc.Common.cancel.localized, role: .cancel) { }
        }
        .alert(
            Inc.Profile.logoutCurrentTitle.localized,
            isPresented: $showLogoutConfirmation
        ) {
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(
                Inc.Profile.logoutCurrent.localized,
                role: .destructive,
                action: logoutCurrent
            )
        } message: {
            Text(Inc.Profile.logoutCurrentMessage.localized)
        }
        .alert(Inc.Profile.logoutFailed.localized, isPresented: $showLogoutError) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
        }
        .alert(
            Inc.Profile.deleteAccountTitle.localized,
            isPresented: $showDeleteConfirmation
        ) {
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(
                Inc.Profile.deleteAccount.localized,
                role: .destructive,
                action: deleteAccount
            )
        } message: {
            Text(Inc.Profile.deleteAccountMessage.localized)
        }
        .alert(Inc.Profile.deleteAccountFailed.localized, isPresented: $showDeleteError) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
        } message: {
            Text(Inc.Profile.deleteAccountFailedMessage.localized)
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 8) {
            Button(action: openPhotoPreview) {
                Group {
                    if let image = photoVM.uiImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        photoVM.profileImage
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(.secondary)
                            .padding(20)
                    }
                }
                .frame(width: 144, height: 144)
                .background(
                    Color(uiColor: .secondarySystemBackground),
                    in: Circle()
                )
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Inc.Profile.openPhoto.localized)

            Text(displayName)
                .font(.system(size: 28, weight: .semibold))
                .multilineTextAlignment(.center)

            if let telegramUsername {
                Text(telegramUsername)
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            ProfileOverviewRow(
                title: Inc.Scanning.scanning.localized,
                systemImage: "dot.radiowaves.left.and.right",
                value: scanningStatusTitle,
                position: .top
            ) {
                showScanningSettings = true
            }

            Divider()
                .padding(.leading, 60)
                .padding(.trailing, 20)

            ProfileOverviewRow(
                title: Inc.NearbyNotifications.settingsTitle.localized,
                systemImage: "bell",
                value: notificationStatusTitle,
                position: .middle,
                action: manageNotificationAuthorization
            )

            Divider()
                .padding(.leading, 60)
                .padding(.trailing, 20)

            ProfileOverviewRow(
                title: Inc.QuickActions.title.localized,
                systemImage: "bolt.fill",
                value: quickActionsStatusTitle,
                position: .bottom
            ) {
                showQuickActions = true
            }
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var peopleCard: some View {
        VStack(spacing: 0) {
            ProfileOverviewRow(
                title: Inc.NearbyProfile.savedMenu.localized,
                systemImage: "heart.fill",
                value: savedProfilesStatusTitle,
                position: .top
            ) {
                showSavedProfiles = true
            }

            Divider()
                .padding(.leading, 60)
                .padding(.trailing, 20)

            ProfileOverviewRow(
                title: Inc.NearbyProfile.blockedMenu.localized,
                systemImage: "person.crop.circle.badge.xmark",
                value: blockedProfilesStatusTitle,
                position: .bottom
            ) {
                showBlockedProfiles = true
            }
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var profileMenu: some View {
        Menu {
            Button {
                showInfoSheet = true
            } label: {
                Label(Inc.Common.Telescan.localized, systemImage: "info.circle")
                    .foregroundStyle(.primary)
            }
            .tint(.primary)

            Button(role: .destructive) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                showLogoutOptions = true
            } label: {
                Label(
                    Inc.Profile.logout.localized,
                    systemImage: "rectangle.portrait.and.arrow.right"
                )
                .foregroundStyle(.red)
            }
            .tint(.red)
            .disabled(isWorking)
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.primary)
        }
        .tint(.primary)
        .accessibilityLabel(Inc.Profile.moreActions.localized)
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var notificationStatusTitle: String {
        switch notificationAuthorizationStatus {
        case .authorized, .provisional, .ephemeral:
            Inc.Settings.statusOn.localized
        case .denied, .notDetermined:
            Inc.Settings.statusOff.localized
        @unknown default:
            Inc.Settings.statusOff.localized
        }
    }

    private var scanningStatusTitle: String {
        coordinator.isScaning
            ? Inc.Settings.statusOn.localized
            : Inc.Settings.statusOff.localized
    }

    private var quickActionsStatusTitle: String {
        quickActions.hasEnabledActions
            ? Inc.Settings.statusOn.localized
            : Inc.Settings.statusOff.localized
    }

    private var blockedProfilesStatusTitle: String {
        let count = peopleViewModel.blockedProfiles.count
        return count == 0
            ? Inc.NearbyProfile.noBlocked.localized
            : String(count)
    }

    private var savedProfilesStatusTitle: String {
        savedPeople.count == 0
            ? Inc.NearbyProfile.noSaved.localized
            : String(savedPeople.count)
    }

    private func manageNotificationAuthorization() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(
                    options: [.alert, .sound]
                )
                await refreshNotificationAuthorizationStatus()
                return
            }

            guard let url = URL(
                string: UIApplication.openNotificationSettingsURLString
            ) else { return }
            await UIApplication.shared.open(url)
        }
    }

    private func refreshNotificationAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current()
            .notificationSettings()
        notificationAuthorizationStatus = settings.authorizationStatus
    }

    private func logoutCurrent() {
        isWorking = true
        Task {
            do {
                try await coordinator.logoutCurrentSession()
            } catch {
                isWorking = false
                showLogoutError = true
            }
        }
    }

    private func deleteAccount() {
        isWorking = true
        Task {
            do {
                try await coordinator.deleteAccount()
            } catch {
                isWorking = false
                showDeleteError = true
            }
        }
    }
}

private struct ProfileOverviewRow: View {
    let title: String
    let systemImage: String
    let value: String?
    let position: ProfileMenuRowPosition
    let action: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        value: String? = nil,
        position: ProfileMenuRowPosition = .single,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.position = position
        self.action = action
    }

    @ViewBuilder
    var body: some View {
        if let action {
            ProfileMenuButton(position: position, action: action) {
                rowContent(showsDisclosureIndicator: true)
            }
        } else {
            rowContent(showsDisclosureIndicator: false)
        }
    }

    private func rowContent(
        showsDisclosureIndicator: Bool
    ) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .frame(width: 24)

            Text(title)
                .font(.system(size: 17))

            Spacer()

            if let value {
                Text(value)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if showsDisclosureIndicator {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
        .frame(height: 58)
        .contentShape(Rectangle())
    }
}

enum ProfileMenuRowPosition {
    case top
    case middle
    case bottom
    case single

    private var topRadius: CGFloat {
        switch self {
        case .top, .single:
            22
        case .middle, .bottom:
            0
        }
    }

    private var bottomRadius: CGFloat {
        switch self {
        case .bottom, .single:
            22
        case .top, .middle:
            0
        }
    }

    var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        )
    }
}

struct ProfileMenuButton<Label: View>: View {
    let position: ProfileMenuRowPosition
    let action: () -> Void
    let label: Label

    @State private var maintainsPressedHighlight = false

    init(
        position: ProfileMenuRowPosition,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.position = position
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button {
            maintainsPressedHighlight = true

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                action()

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    maintainsPressedHighlight = false
                }
            }
        } label: {
            label
        }
        .buttonStyle(
            ProfileMenuPressedButtonStyle(
                position: position,
                maintainsHighlight: maintainsPressedHighlight
            )
        )
    }
}

private struct ProfileMenuPressedButtonStyle: ButtonStyle {
    let position: ProfileMenuRowPosition
    let maintainsHighlight: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = configuration.isPressed || maintainsHighlight

        configuration.label
            .background(
                isHighlighted ? Color(uiColor: .secondarySystemFill) : .clear,
                in: position.shape
            )
            .animation(
                .easeOut(duration: 0.12),
                value: isHighlighted
            )
    }
}
