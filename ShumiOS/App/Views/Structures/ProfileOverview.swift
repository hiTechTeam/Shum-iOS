import SwiftUI
import UserNotifications

struct ProfileOverviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var peopleViewModel: PeopleViewModel

    @ObservedObject var chat: SpotchatRuntime
    @ObservedObject var authCodeViewModel: LocalProfileViewModel
    @ObservedObject private var photoVM: ProfilePhotoViewModel
    @ObservedObject private var savedPeople = SavedPeopleStateStore.shared
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared

    @State private var showQR = false
    @State private var showPrivacy = false
    @State private var showInfoSheet = false
    @State private var showLogoutOptions = false
    @State private var showBlockedProfiles = false
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
        chat: SpotchatRuntime,
        authCodeViewModel: LocalProfileViewModel,
        photoViewModel: ProfilePhotoViewModel
    ) {
        self.chat = chat
        self.authCodeViewModel = authCodeViewModel
        self.photoVM = photoViewModel
    }

    private var displayName: String {
        normalized(authCodeViewModel.localName)
            ?? Inc.Profile.notSpecified.localized
    }

    private var messengerUsername: String? {
        normalized(authCodeViewModel.localUsername)
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
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 30)
                .padding(.bottom, 36)
            }
            .shumAlwaysBounce()
            .refreshable { await coordinator.refreshSession() }
        }
        .shumOnChange(of: authCodeViewModel.localPhotoURL) { _, value in
            photoVM.loadPhotoFromURL(value)
        }
        .shumOnChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshNotificationAuthorizationStatus()
                await peopleViewModel.synchronizeBlockedProfiles()
                peopleViewModel.refreshEncounterHistory()
            }
        }
        .task {
            await refreshNotificationAuthorizationStatus()
            await peopleViewModel.synchronizeBlockedProfiles()
            peopleViewModel.refreshEncounterHistory()
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { showQR = true } label: { Image(systemName: "qrcode") }
                    .accessibilityLabel("Мой QR-код")

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
        .sheet(isPresented: $showQR) {
            if let card = coordinator.chat?.permanent?.ownCard { SpotchatQRView(card: card) }
        }
        .sheet(isPresented: $showPrivacy) {
            if let chat = coordinator.chat {
                NavigationStack { SpotchatPrivacySettings(runtime: chat) }
            }
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
            NSLocalizedString("local.delete.title", comment: ""),
            isPresented: $showDeleteConfirmation
        ) {
            Button(Inc.Common.cancel.localized, role: .cancel) { }
            Button(
                NSLocalizedString("local.delete.action", comment: ""),
                role: .destructive,
                action: deleteAccount
            )
        } message: {
            Text(NSLocalizedString("local.delete.message", comment: ""))
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


        }
        .frame(maxWidth: .infinity)
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            ProfileOverviewRow(title: "Конфиденциальность", systemImage: "lock.shield",
                value: "", position: .top) { showPrivacy = true }
            Divider().padding(.leading, 60).padding(.trailing, 20)
            ProfileOverviewRow(title: "О приложении", systemImage: "info.circle",
                value: "Shum", position: .bottom) { showInfoSheet = true }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
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

    private var quickActionsStatusTitle: String {
        quickActions.hasEnabledActions
            ? Inc.Settings.statusOn.localized
            : Inc.Settings.statusOff.localized
    }

    private func manageNotificationAuthorization() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(
                    options: [.alert, .sound, .badge]
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
    let accentValue: String?
    let value: String?
    let position: ProfileMenuRowPosition
    let action: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        accentValue: String? = nil,
        value: String? = nil,
        position: ProfileMenuRowPosition = .single,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accentValue = accentValue
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

            if let accentValue {
                Text(accentValue)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

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
