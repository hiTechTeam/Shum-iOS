import SwiftUI
import UserNotifications

enum ShumProfileRoute: Hashable {
    case encounters
    case conversation(ShumPeer)
    case ownQR

    var hidesTabBar: Bool {
        switch self {
        case .conversation, .ownQR: true
        case .encounters: false
        }
    }
}

struct ProfileOverviewView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: AppCoordinator

    @ObservedObject var chat: ShumRuntime
    @ObservedObject var authCodeViewModel: LocalProfileViewModel
    @ObservedObject private var photoVM: ProfilePhotoViewModel
    let open: (ShumProfileRoute) -> Void
    @ObservedObject private var quickActions = QuickActionsSettingsStore.shared
    @ObservedObject private var appLock = ShumAppLock.shared
    @ObservedObject private var appearance = ShumAppearanceStore.shared

    @State private var showPrivacy = false
    @State private var showScanningSettings = false
    @State private var showInfoSheet = false
    @State private var showLogoutOptions = false
    @State private var showBlockedProfiles = false
    @State private var showQuickActions = false
    @State private var showSecurity = false
    @State private var showAppearance = false
    @State private var showLogoutConfirmation = false
    @State private var showLogoutError = false
    @State private var showDeleteConfirmation = false
    @State private var showDeleteError = false
    @State private var showPhotoPreview = false
    @State private var isWorking = false
    @State private var notificationAuthorizationStatus:
        UNAuthorizationStatus = .notDetermined

    init(
        chat: ShumRuntime,
        authCodeViewModel: LocalProfileViewModel,
        photoViewModel: ProfilePhotoViewModel,
        open: @escaping (ShumProfileRoute) -> Void
    ) {
        self.chat = chat
        self.authCodeViewModel = authCodeViewModel
        self.photoVM = photoViewModel
        self.open = open
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
            appearance.palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    settingsCard
                    applicationCard
                    encounterCard
                }
                .padding(.horizontal, 20)
                .padding(.top, 30)
                .padding(.bottom, 36)
            }
            .shumAlwaysBounce()
            .refreshable { await coordinator.refreshSession() }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .shumOnChange(of: authCodeViewModel.localPhotoURL) { _, value in
            photoVM.loadPhotoFromURL(value)
        }
        .shumOnChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshNotificationAuthorizationStatus()
                coordinator.refreshNotificationState()
            }
        }
        .task {
            await refreshNotificationAuthorizationStatus()
        }
        .toolbar {
            ProfileAvatarToolbarItem {
                profileAvatarButton
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { open(.ownQR) } label: { Image(systemName: "qrcode") }
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
        .sheet(isPresented: $showPrivacy) {
            if let chat = coordinator.chat {
                NavigationStack { ShumPrivacySettings(runtime: chat) }
            }
        }
        .sheet(isPresented: $showScanningSettings) {
            ScanningSettingsSheet()
                .environmentObject(coordinator)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showInfoSheet) {
            InfoSheetView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBlockedProfiles) {
            BlockedProfilesView(runtime: chat)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showQuickActions) {
            QuickActionsSettingsSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showSecurity) {
            ShumSecuritySettingsView(fingerprint: coordinator.identityFingerprint)
        }
        .navigationDestination(isPresented: $showAppearance) {
            ShumAppearanceSettingsView()
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

    private var profileAvatarButton: some View {
        Group {
            if #available(iOS 26.0, *) {
                avatarButton
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
            } else {
                avatarButton
                    .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(Inc.Profile.openPhoto.localized)
    }

    private var avatarButton: some View {
        Button(action: openPhotoPreview) {
            Group {
                if let image = photoVM.uiImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .background(Color(uiColor: .secondarySystemBackground))
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .scaledToFit()
                        .symbolRenderingMode(.hierarchical)
                        .padding(2)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .foregroundStyle(.primary)
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
            Divider().padding(.leading, 60).padding(.trailing, 20)
            ProfileOverviewRow(
                title: Inc.NearbyNotifications.settingsTitle.localized,
                systemImage: "bell",
                value: notificationStatusTitle,
                position: .middle,
                action: manageNotificationAuthorization
            )
            Divider().padding(.leading, 60).padding(.trailing, 20)
            ProfileOverviewRow(title: "Безопасность", systemImage: "checkmark.shield",
                value: appLock.preferredMethodTitle,
                position: .middle) {
                    showSecurity = true
                }
            Divider().padding(.leading, 60).padding(.trailing, 20)
            ProfileOverviewRow(title: "Конфиденциальность", systemImage: "lock.shield",
                value: "", position: .bottom) { showPrivacy = true }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private var applicationCard: some View {
        VStack(spacing: 0) {
            ProfileOverviewRow(
                title: "О приложении",
                systemImage: "info.circle",
                value: "Shum",
                position: .top
            ) {
                showInfoSheet = true
            }
            Divider().padding(.leading, 60).padding(.trailing, 20)
            ProfileOverviewRow(
                title: "Оформление",
                systemImage: "paintpalette",
                theme: appearance.theme,
                position: .bottom
            ) {
                showAppearance = true
            }
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
    }

    private var encounterCard: some View {
        VStack(spacing: 0) {
            ProfileOverviewRow(
                title: Inc.Tabs.metTitle.localized,
                systemImage: "clock.arrow.circlepath",
                accentValue: (chat.permanent?.unviewedEncounterCount ?? 0) > 0
                    ? "+\(chat.permanent?.unviewedEncounterCount ?? 0)"
                    : nil,
                value: String(chat.permanent?.encounterHistory.count ?? 0),
                position: .top
            ) {
                open(.encounters)
            }

            Divider().padding(.leading, 60).padding(.trailing, 20)

            ProfileOverviewRow(
                title: Inc.NearbyProfile.blockedMenu.localized,
                systemImage: "person.crop.circle.badge.xmark",
                value: String(chat.permanent?.state.blocked?.count ?? 0),
                position: .bottom
            ) {
                showBlockedProfiles = true
            }
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
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

    private var scanningStatusTitle: String {
        coordinator.isScaning
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
                coordinator.refreshNotificationState()
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

private struct ShumAppearanceSettingsView: View {
    @ObservedObject private var appearance = ShumAppearanceStore.shared
    @ObservedObject private var appIcons = ShumAppIconStore.shared

    var body: some View {
        List {
            Section {
                Toggle("Системная", isOn: Binding(
                    get: { appearance.followsSystem },
                    set: { appearance.setFollowsSystem($0) }
                ))
            } footer: {
                Text("Светлая или тёмная тема Classic выбирается по оформлению устройства. Выбор темы ниже отключает системный режим.")
                    .font(.system(size: 13, weight: .regular))
                    .textCase(nil)
            }

            Section {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: 4
                    ),
                    spacing: 16
                ) {
                    ForEach(ShumAppearanceStore.Theme.allCases) { theme in
                        Button {
                            appearance.select(theme)
                        } label: {
                            ShumThemeChoice(
                                theme: theme,
                                isSelected: appearance.theme == theme
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 8)
            } header: {
                ShumAppearanceSectionTitle("Тема приложения")
            } footer: {
                Text("Тема меняет цвет кнопок, выбранных элементов и пиксельных иконок Shum.")
                    .font(.system(size: 13, weight: .regular))
                    .textCase(nil)
            }

            Section {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(), spacing: 8),
                        count: 4
                    ),
                    spacing: 16
                ) {
                    ForEach(ShumAppIconStore.Icon.allCases) { icon in
                        Button {
                            appIcons.select(icon)
                        } label: {
                            ShumAppIconChoice(
                                icon: icon,
                                isSelected: appIcons.selected == icon
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(appIcons.isChanging)
                    }
                }
                .padding(.vertical, 8)
            } header: {
                ShumAppearanceSectionTitle("Иконка приложения")
            } footer: {
                Text("Иконка выбирается отдельно от темы приложения.")
                    .font(.system(size: 13, weight: .regular))
                    .textCase(nil)
            }
        }
        .navigationTitle("Оформление")
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Не удалось изменить иконку",
            isPresented: Binding(
                get: { appIcons.errorMessage != nil },
                set: { if !$0 { appIcons.errorMessage = nil } }
            )
        ) {
            Button("Понятно", role: .cancel) {
                appIcons.errorMessage = nil
            }
        } message: {
            Text(appIcons.errorMessage ?? "")
        }
    }
}

private struct ShumAppearanceSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

private struct ShumThemeChoice: View {
    let theme: ShumAppearanceStore.Theme
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 7) {
            ShumThemeSwatch(theme: theme)
                .frame(width: 42, height: 42)
                .padding(3)
                .overlay {
                    Circle()
                        .stroke(
                            isSelected ? theme.accentColor : .clear,
                            lineWidth: 2
                        )
                }

            Text(theme.title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isSelected ? theme.accentColor : Color.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.74)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct ShumThemeSwatch: View {
    let theme: ShumAppearanceStore.Theme

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let circle = Path(ellipseIn: bounds)
            context.fill(circle, with: .color(theme.palette.canvas))

            var accentHalf = Path()
            accentHalf.move(to: CGPoint(x: 0, y: size.height))
            accentHalf.addLine(to: CGPoint(x: size.width, y: size.height))
            accentHalf.addLine(to: CGPoint(x: size.width, y: 0))
            accentHalf.closeSubpath()
            context.fill(accentHalf, with: .color(theme.accentColor))
        }
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

private struct ShumAppIconChoice: View {
    let icon: ShumAppIconStore.Icon
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(icon.backgroundColor)
                .frame(width: 60, height: 60)
                .overlay {
                    ShumLogoMark(color: icon.markColor)
                        .frame(width: 39, height: 39)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(
                            isSelected
                                ? Color.accentColor
                                : Color.secondary.opacity(0.20),
                            lineWidth: isSelected ? 2 : 0.75
                        )
                }

            Text(icon.title)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

private struct ProfileAvatarToolbarItem<Content: View>: ToolbarContent {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) {
                content
            }
            .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) {
                content
                    .frame(width: 40, height: 40)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: Circle()
                    )
                    .contentShape(Circle())
            }
        }
    }
}

private struct ProfileOverviewRow: View {
    let title: String
    let systemImage: String
    let accentValue: String?
    let value: String?
    let theme: ShumAppearanceStore.Theme?
    let position: ProfileMenuRowPosition
    let action: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        accentValue: String? = nil,
        value: String? = nil,
        theme: ShumAppearanceStore.Theme? = nil,
        position: ProfileMenuRowPosition = .single,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accentValue = accentValue
        self.value = value
        self.theme = theme
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
                .font(.system(size: 17, weight: .regular))

            Spacer()

            if let accentValue {
                Text(accentValue)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }

            if let value {
                Text(value)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let theme {
                ShumThemeSwatch(theme: theme)
                    .frame(width: 24, height: 24)
                    .accessibilityLabel("Выбрана тема \(theme.title)")
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
