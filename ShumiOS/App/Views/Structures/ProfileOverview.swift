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

/// The Profile tab: the own avatar, name and people met, with settings
/// behind the gear.
struct ProfileOverviewView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    @ObservedObject var chat: ShumRuntime
    @ObservedObject var authCodeViewModel: LocalProfileViewModel
    @ObservedObject private var photoVM: ProfilePhotoViewModel
    let open: (ShumProfileRoute) -> Void
    @ObservedObject private var appearance = ShumAppearanceStore.shared

    @Binding var showSecurity: Bool
    @State private var showSettings = false
    @State private var editingName = false
    @State private var editingAvatar = false
    @State private var choosingProfile = false
    @State private var creatingProfile = false
    @State private var restoringProfile = false

    init(
        chat: ShumRuntime,
        authCodeViewModel: LocalProfileViewModel,
        photoViewModel: ProfilePhotoViewModel,
        showSecurity: Binding<Bool>,
        open: @escaping (ShumProfileRoute) -> Void
    ) {
        self.chat = chat
        self.authCodeViewModel = authCodeViewModel
        self.photoVM = photoViewModel
        _showSecurity = showSecurity
        self.open = open
    }

    private var displayName: String {
        authCodeViewModel.localName.flatMap(ShumOwnProfile.normalized)
            ?? Inc.Profile.notSpecified.localized
    }

    var body: some View {
        ZStack {
            appearance.palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 12) {
                    nameCard
                    encountersCard
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
            .shumAlwaysBounce()
            .refreshable { await coordinator.refreshSession() }
        }
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ProfileAvatarToolbarItem {
                ProfileAvatarMenu(
                    name: displayName,
                    seed: LocalCardStore.shared.ownManifest?.body.avatarSeed,
                    editAvatar: { editingAvatar = true },
                    chooseProfile: { choosingProfile = true },
                    createProfile: { creatingProfile = true }
                )
                .equatable()
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                // Monochrome in every theme.
                Button { open(.ownQR) } label: {
                    Image(systemName: "qrcode").foregroundStyle(.primary)
                }
                .tint(.primary)
                .accessibilityLabel("Мой QR-код".localized)
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").foregroundStyle(.primary)
                }
                .tint(.primary)
                .accessibilityLabel("Настройки".localized)
            }
        }
        .navigationDestination(isPresented: $showSettings) {
            ShumSettingsView(chat: chat, showSecurity: $showSecurity)
        }
        .shumSheet(isPresented: $editingName) {
            ShumNameSheet(profile: authCodeViewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .shumSheet(isPresented: $choosingProfile) {
            ShumProfilePickerSheet {
                choosingProfile = false
                creatingProfile = true
            } restore: {
                choosingProfile = false
                restoringProfile = true
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .shumRestoresProfile(isPresented: $restoringProfile)
        .shumSheet(isPresented: $creatingProfile) {
            ShumNewProfileSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .shumSheet(isPresented: $editingAvatar) {
            PixelAvatarGeneratorSheet(currentSeed: photoVM.avatarSeed) { seed in
                if photoVM.usePixelAvatar(seed: seed) {
                    editingAvatar = false
                }
            }
            .presentationDetents([.height(470)])
            .presentationDragIndicator(.visible)
        }
        .alert("local.photo.save.error", isPresented: $photoVM.saveFailed) {
            Button(Inc.Common.okey.localized, role: .cancel) { }
        }
    }

    private var nameCard: some View {
        ProfileMenuButton(position: .single, action: { editingName = true }) {
            HStack(spacing: 12) {
                Text("Имя".localized)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(displayName)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 20)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityLabel("Имя".localized)
        .accessibilityValue(displayName)
    }

    private var encountersCard: some View {
        ProfileOverviewRow(
            title: Inc.Tabs.metTitle.localized,
            systemImage: "clock.arrow.circlepath",
            accentValue: (chat.permanent?.unviewedEncounterCount ?? 0) > 0
                ? "+\(chat.permanent?.unviewedEncounterCount ?? 0)"
                : nil,
            value: String(chat.permanent?.encounterHistory.count ?? 0),
            position: .single
        ) {
            open(.encounters)
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// The own profile's name as this device keeps it.
@MainActor
enum ShumOwnProfile {
    static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The name, as the contact sees it in chats.
private struct ShumNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var profile: LocalProfileViewModel
    @State private var name = ""
    @FocusState private var focused: Bool
    private static let limit = 50

    private var valid: Bool { ShumProfileValidation.name(name) != nil }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Имя пользователя".localized, text: $name)
                    .textContentType(.nickname)
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityIdentifier("local.name")
                    .shumOnChange(of: name) { _, value in
                        if value.count > Self.limit { name = String(value.prefix(Self.limit)) }
                    }

                HStack {
                    Text("Так вас видят в чатах".localized)
                    Spacer()
                    Text("\(name.count) / \(Self.limit)")
                        .monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)

                if let error = profile.saveError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
                Spacer()
            }
            .padding(16)
            .background(ShumThemeCanvas().ignoresSafeArea())
            .navigationTitle("Имя".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена".localized) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово".localized, action: save)
                        .fontWeight(.semibold)
                        .disabled(!valid)
                }
            }
            .onAppear {
                name = profile.localName ?? ""
                profile.saveError = nil
                focused = true
            }
        }
    }

    private func save() {
        guard let value = ShumProfileValidation.name(name) else { return }
        if profile.updateName(value) { dismiss() }
    }
}

/// The profiles on this iPhone: tap one to open it.
private struct ShumProfilePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject private var profiles = ShumProfileList.shared
    let create: () -> Void
    let restore: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(profiles.entries) { entry in
                        Button {
                            dismiss()
                            coordinator.switchProfile(to: entry.id)
                        } label: {
                            HStack(spacing: 14) {
                                ShumAvatar(name: entry.name, size: 40,
                                           imageData: entry.avatarSeed.flatMap(ShumPixelAvatarGenerator.data(seed:)))
                                Text(entry.name)
                                    .font(.system(size: 17, weight: entry.id == profiles.active ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer()
                                if entry.id == profiles.active {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button(action: create) {
                        HStack(spacing: 14) {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                            Text("Создать новый профиль".localized)
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button(action: restore) {
                        HStack(spacing: 14) {
                            Image(systemName: "externaldrive.badge.timemachine")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                            Text("Восстановить из копии".localized)
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("У каждого профиля свои чаты, контакты и ключи".localized)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .textCase(nil)
                }
            }
            .shumGroupedScreenBackground()
            .navigationTitle("Профили".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Inc.Common.close.localized) { dismiss() }
                }
            }
        }
    }
}

/// A new profile in two steps: its name, then its pixel avatar.
struct ShumNewProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var name = ""
    @State private var choosingAvatar = false
    @State private var seed = UInt64.random(in: .min ... .max)
    @State private var showCeremony = false
    /// The prepared profile, kept when the ceremony is retried.
    @State private var createdID: String?
    @FocusState private var focused: Bool
    private static let limit = 50

    private var valid: Bool { ShumProfileValidation.name(name) != nil }

    var body: some View {
        NavigationStack {
            Group {
                if choosingAvatar { avatarStep } else { nameStep }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(ShumThemeCanvas().ignoresSafeArea())
            .navigationDestination(isPresented: $showCeremony) {
                // The same key ceremony as registration; the new profile's
                // keys are made while it runs and it opens on "Continue".
                RegistrationSecurityCreationView(
                    prepare: {
                        if createdID == nil {
                            createdID = coordinator.prepareProfile(name: name, avatarSeed: seed)
                        }
                        return createdID != nil
                    },
                    onContinue: {
                        let id = createdID
                        dismiss()
                        if let id {
                            DispatchQueue.main.async { coordinator.switchProfile(to: id) }
                        }
                    }
                )
            }
            .navigationTitle("Новый профиль".localized)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if choosingAvatar {
                        Button("Назад".localized) { choosingAvatar = false }
                    } else {
                        Button(Inc.Common.close.localized) { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Text(choosingAvatar ? "2 из 2".localized : "1 из 2".localized)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var nameStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Имя".localized)
                    .font(.system(size: 30, weight: .bold))
                Text("Так вас увидят собеседники в этом профиле".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 8) {
                TextField("Имя пользователя".localized, text: $name)
                    .textContentType(.nickname)
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .submitLabel(.next)
                    .onSubmit { if valid { choosingAvatar = true } }
                    .padding(.horizontal, 16)
                    .frame(height: 50)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shumOnChange(of: name) { _, value in
                        if value.count > Self.limit { name = String(value.prefix(Self.limit)) }
                    }
                HStack {
                    Text("Можно не своё настоящее имя".localized)
                    Spacer()
                    Text("\(name.count) / \(Self.limit)").monospacedDigit()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            }

            Button { choosingAvatar = true } label: { Text("Далее".localized) }
                .buttonStyle(ShumPrimaryButtonStyle())
                .disabled(!valid)
                .opacity(valid ? 1 : 0.45)
        }
        .onAppear { focused = true }
    }

    private var avatarStep: some View {
        VStack(spacing: 16) {
            VStack(spacing: 6) {
                Text("Аватар".localized)
                    .font(.system(size: 30, weight: .bold))
                Text("Найди аватар себе по душе. Свой характер, свой стиль.".localized)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 12)

            Image(uiImage: ShumPixelAvatarGenerator.image(seed: seed))
                .resizable()
                .interpolation(.none)
                .frame(width: 184, height: 184)
                .clipShape(Circle())
                .accessibilityLabel("Предпросмотр аватара".localized)

            Text(name.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            Button {
                var next = UInt64.random(in: .min ... .max)
                if next == seed { next &+= 1 }
                seed = next
            } label: {
                Label("Другой вариант".localized, systemImage: "arrow.clockwise")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }
            .buttonStyle(.plain)

            Button { showCeremony = true } label: { Text("Создать профиль".localized) }
                .buttonStyle(ShumPrimaryButtonStyle())

            Text("Отдельные контакты, чаты и ключ шифрования. Переключаться можно в любой момент.".localized)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Settings behind the gear on the Profile tab.
struct ShumSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: AppCoordinator
    @ObservedObject var chat: ShumRuntime
    @Binding var showSecurity: Bool
    @ObservedObject private var appearance = ShumAppearanceStore.shared
    @ObservedObject private var language = ShumLanguageStore.shared

    @State private var showScanningSettings = false
    @State private var showInfoSheet = false
    @State private var showAppearance = false
    @State private var showLanguage = false
    @State private var notificationAuthorizationStatus:
        UNAuthorizationStatus = .notDetermined

    var body: some View {
        ZStack {
            appearance.palette.canvas.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    section("Общение".localized) { communicationCard }
                    section("Приложение".localized) { applicationCard }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 36)
            }
            .shumAlwaysBounce()
        }
        .navigationTitle("Настройки".localized)
        .navigationBarTitleDisplayMode(.inline)
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
        .shumSheet(isPresented: $showScanningSettings) {
            ScanningSettingsSheet()
                .environmentObject(coordinator)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .shumSheet(isPresented: $showInfoSheet) {
            InfoSheetView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $showSecurity) {
            ShumSecuritySettingsView(
                runtime: chat,
                fingerprint: coordinator.identityFingerprint
            )
        }
        .navigationDestination(isPresented: $showAppearance) {
            ShumAppearanceSettingsView()
        }
        .navigationDestination(isPresented: $showLanguage) {
            ShumLanguageSettingsView()
        }
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.leading, 16)

            content()
        }
    }

    private var communicationCard: some View {
        VStack(spacing: 0) {
            ProfileOverviewRow(
                title: Inc.Scanning.scanning.localized,
                systemImage: "dot.radiowaves.left.and.right",
                value: coordinator.isScaning
                    ? Inc.Settings.statusOn.localized
                    : Inc.Settings.statusOff.localized,
                position: .top
            ) {
                showScanningSettings = true
            }
            Divider().padding(.leading, 60).padding(.trailing, 20)
            ProfileOverviewRow(
                title: Inc.NearbyNotifications.settingsTitle.localized,
                systemImage: "bell",
                value: notificationStatusTitle,
                position: .bottom,
                action: manageNotificationAuthorization
            )
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private var applicationCard: some View {
        VStack(spacing: 0) {
            ProfileOverviewRow(
                title: "Безопасность и данные".localized,
                systemImage: "checkmark.shield",
                position: .top
            ) {
                showSecurity = true
            }
            Divider().padding(.leading, 60).padding(.trailing, 20)
            ProfileOverviewRow(
                title: "Оформление".localized,
                systemImage: "paintpalette",
                theme: appearance.theme,
                position: .middle
            ) {
                showAppearance = true
            }
            Divider().padding(.leading, 60).padding(.trailing, 20)
            ProfileOverviewRow(
                title: "Язык".localized,
                systemImage: "globe",
                value: language.selectedTitle,
                position: .middle
            ) {
                showLanguage = true
            }
            Divider().padding(.leading, 60).padding(.trailing, 20)
            ProfileOverviewRow(
                title: Inc.Info.aboutApp.localized,
                systemImage: "info.circle",
                position: .bottom
            ) {
                showInfoSheet = true
            }
        }
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
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
}

private struct ShumLanguageSettingsView: View {
    @ObservedObject private var language = ShumLanguageStore.shared

    var body: some View {
        List {
            Section {
                ForEach(ShumLanguageStore.Language.allCases) { option in
                    Button {
                        language.select(option)
                    } label: {
                        HStack {
                            Text(option.nativeTitle)
                                .foregroundStyle(.primary)
                            Spacer()
                            if language.selected == option {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Язык интерфейса меняется сразу и сохраняется на этом устройстве.".localized)
                    .textCase(nil)
            }
        }
        .shumGroupedScreenBackground()
        .navigationTitle("Язык".localized)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ShumAppearanceSettingsView: View {
    @ObservedObject private var appearance = ShumAppearanceStore.shared
    @ObservedObject private var appIcons = ShumAppIconStore.shared

    var body: some View {
        List {
            Section {
                Toggle("Системная".localized, isOn: Binding(
                    get: { appearance.followsSystem },
                    set: { appearance.setFollowsSystem($0) }
                ))
            } footer: {
                Text("Светлая или тёмная тема Classic выбирается по оформлению устройства. Выбор темы ниже отключает системный режим.".localized)
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
                ShumAppearanceSectionTitle("Тема приложения".localized)
            } footer: {
                Text("Тема меняет цвет кнопок, выбранных элементов и пиксельных иконок Shum.".localized)
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
                ShumAppearanceSectionTitle("Иконка приложения".localized)
            } footer: {
                Text("Иконка выбирается отдельно от темы приложения.".localized)
                    .font(.system(size: 13, weight: .regular))
                    .textCase(nil)
            }
        }
        .shumGroupedScreenBackground()
        .navigationTitle("Оформление".localized)
        .navigationBarTitleDisplayMode(.inline)
        .alert(
            "Не удалось изменить иконку".localized,
            isPresented: Binding(
                get: { appIcons.errorMessage != nil },
                set: { if !$0 { appIcons.errorMessage = nil } }
            )
        ) {
            Button("Понятно".localized, role: .cancel) {
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

/// The own avatar and its menu. The profile screen redraws whenever
/// anything in Shum changes; rebuilding an open menu with it makes the menu
/// flicker, so this redraws only for a new name or avatar.
private struct ProfileAvatarMenu: View, Equatable {
    let name: String
    let seed: UInt64?
    let editAvatar: () -> Void
    let chooseProfile: () -> Void
    let createProfile: () -> Void

    static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.seed == b.seed
    }

    var body: some View {
        Menu {
            Button(action: editAvatar) {
                Label("Изменить аватар".localized, systemImage: "pencil")
            }
            Button(action: chooseProfile) {
                Label("Выбрать профиль".localized, systemImage: "arrow.left.arrow.right")
            }
            Button(action: createProfile) {
                Label("Создать новый профиль".localized, systemImage: "plus")
            }
        } label: {
            ShumAvatar(name: name, size: 34, imageData: seed.flatMap(ShumPixelAvatarGenerator.data(seed:)))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        // A plain label: no padding of its own, on every iOS.
        .menuStyle(.button)
        .buttonStyle(.plain)
        // Menu icons stay monochrome in every theme.
        .tint(.primary)
        .accessibilityLabel("Изменить аватар".localized)
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
            // The avatar is round itself; a menu label would shift a
            // background circle off it.
            ToolbarItem(placement: .topBarLeading) {
                content
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
                    .accessibilityLabel(String.localizedFormat("Выбрана тема %@".localized, theme.title))
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
        ShumPressButton(action: action, style: ProfileMenuPressedButtonStyle(position: position)) {
            label
        }
    }
}

private struct ProfileMenuPressedButtonStyle: ButtonStyle {
    let position: ProfileMenuRowPosition

    func makeBody(configuration: Configuration) -> some View {
        let isHighlighted = configuration.isPressed

        configuration.label
            .background(
                isHighlighted ? Color(uiColor: .secondarySystemFill) : .clear,
                in: position.shape
            )
            .animation(
                isHighlighted ? nil : .easeOut(duration: 0.08),
                value: isHighlighted
            )
    }
}
