import SwiftUI
import UserNotifications

struct ProfileOverviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @ObservedObject var authCodeViewModel: CodeViewModel
    @ObservedObject private var photoVM: ProfilePhotoViewModel

    @State private var showScanningSettings = false
    @State private var showQuickChatSettings = false
    @State private var showInfoSheet = false
    @State private var showLogoutOptions = false
    @State private var showBlockedProfiles = false
    @State private var showLogoutConfirmation = false
    @State private var showLogoutError = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var showPhotoPreview = false
    @State private var isWorking = false
    @State private var notificationAuthorizationStatus:
        UNAuthorizationStatus = .notDetermined
    @AppStorage(Keys.isQuickChatEnabled.rawValue)
    private var isQuickChatEnabled = false

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
            Color.tsBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    profileHeader
                    settingsCard
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
        .sheet(isPresented: $showQuickChatSettings) {
            QuickChatSettingsSheet(isEnabled: $isQuickChatEnabled)
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
                value: scanningStatusTitle
            ) {
                showScanningSettings = true
            }

            Divider().padding(.leading, 60)

            ProfileOverviewRow(
                title: Inc.NearbyNotifications.settingsTitle.localized,
                systemImage: "bell",
                value: notificationStatusTitle,
                action: manageNotificationAuthorization
            )

            Divider().padding(.leading, 60)

            ProfileOverviewRow(
                title: Inc.Settings.quickChat.localized,
                systemImage: "paperplane",
                value: quickChatStatusTitle
            ) {
                showQuickChatSettings = true
            }

            Divider().padding(.leading, 60)

            ProfileOverviewRow(
                title: Inc.NearbyProfile.blockedMenu.localized,
                systemImage: "person.crop.circle.badge.xmark",
                value: blockedProfilesStatusTitle
            ) {
                showBlockedProfiles = true
            }
        }
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 22)
        )
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

    private var quickChatStatusTitle: String {
        isQuickChatEnabled
            ? Inc.Settings.statusOn.localized
            : Inc.Settings.statusOff.localized
    }

    private var blockedProfilesStatusTitle: String {
        let count = peopleViewModel.blockedProfiles.count
        return count == 0
            ? Inc.NearbyProfile.noBlocked.localized
            : String(count)
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

private struct QuickChatSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var isEnabled: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text(Inc.Settings.quickChatDescription.localized)
                    .telescanDescriptionStyle()
                    .frame(maxWidth: .infinity, alignment: .leading)

                Toggle(
                    Inc.Settings.quickChat.localized,
                    isOn: $isEnabled
                )
                .font(.body.weight(.medium))
                .toggleStyle(.switch)
                .tint(.green)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(
                    Color.grOne,
                    in: RoundedRectangle(cornerRadius: 13)
                )

                Spacer(minLength: 0)
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(Inc.Settings.quickChat.localized)
                        .telescanSheetTitleStyle()
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(Inc.Common.close.localized) {
                        dismiss()
                    }
                }
            }
            .onChange(of: isEnabled) {
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }
}

private struct ProfileOverviewRow: View {
    let title: String
    let systemImage: String
    let value: String?
    let action: () -> Void

    init(
        title: String,
        systemImage: String,
        value: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.action = action
    }

    var body: some View {
        Button(action: action) {
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

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 20)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
