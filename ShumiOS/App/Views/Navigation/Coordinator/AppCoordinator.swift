import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    @Published var isRegistered = false
    @Published private(set) var needsSecuritySetup = false
    @Published var authenticationFlowID = UUID()
    @Published var hasCompletedInitialSessionRefresh = true
    @Published var nearbyNotificationNavigationRequest = UUID()
    @Published var showSplash = true
    @Published var isScaning = false
    @Published private(set) var chat: SpotchatRuntime?
    @Published var deletionError: String?
    @Published var invitation: SpotchatContactCard?
    @Published var invitationError: String?
    @Published var deletingProfile = false
    let authCodeViewModel: LocalProfileViewModel
    let peopleViewModel: PeopleViewModel
    let profilePhotoViewModel: ProfilePhotoViewModel
    private let deletion = SpotchatDeletionService.live()
    private var photoObserver: NSObjectProtocol?
    private var active = false

    init() {
        let store = LocalCardStore.shared
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-ShumPreview"), store.ownManifest == nil {
            _ = try? store.saveOwn(name: "Руслан", bio: "Пробую Shum", photo: nil)
        }
        #endif
        authCodeViewModel = LocalProfileViewModel()
        profilePhotoViewModel = ProfilePhotoViewModel()
        peopleViewModel = PeopleViewModel(bleManager: ShumInactiveCardRadio())
        #if DEBUG
        if TestEnvironment.isRunningTests { return }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        let previewsOnboarding = ProcessInfo.processInfo.arguments.contains("-ShumPreviewOnboarding")
        #else
        let previewsOnboarding = false
        #endif
        let hasProfile = store.ownManifest != nil
        let registrationCompleted = UserDefaults.standard.bool(
            forKey: Keys.isReg.rawValue
        )
        isRegistered = hasProfile && registrationCompleted && !previewsOnboarding
        needsSecuritySetup = hasProfile && !registrationCompleted && !previewsOnboarding
        isScaning = isRegistered && UserDefaults.standard.bool(forKey: Keys.isScaning.rawValue)
        if deletion.hasDeletion {
            deletingProfile = true
            finishDeletion()
        } else if isRegistered {
            prepareMessaging()
        } else if needsSecuritySetup {
            _ = prepareRegistrationSecurity()
        }
        photoObserver = NotificationCenter.default.addObserver(forName: .localCardChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.authCodeViewModel.restoreLocalProfile()
                self?.synchronizeProfile()
            }
        }
    }
    deinit { if let photoObserver { NotificationCenter.default.removeObserver(photoObserver) } }
    func start() -> AnyView {
        AnyView(AppCoordinatorView().environmentObject(self)
            .environmentObject(authCodeViewModel).environmentObject(peopleViewModel))
    }
    private func prepareMessaging() {
        guard !deletingProfile, isRegistered else { return }
        createMessaging(
            bluetoothEnabled: isScaning && !ShumAppLock.shared.isLocked
        )
    }
    private func createMessaging(bluetoothEnabled: Bool) {
        guard chat == nil else {
            chat?.setBluetoothEnabled(bluetoothEnabled)
            return
        }
        let model = SpotchatRuntime.live()
        model.deleteProfileHandler = { [weak self] in
            Task { @MainActor in try? await self?.deleteAccount() }
        }
        model.setBluetoothEnabled(bluetoothEnabled)
        model.setAppActive(false)
        chat = model
        synchronizeProfile()
    }
    @discardableResult
    func prepareRegistrationSecurity() -> Bool {
        guard !deletingProfile, LocalCardStore.shared.ownManifest != nil else {
            return false
        }
        createMessaging(bluetoothEnabled: false)
        synchronizeProfile()
        return chat?.isReady == true && chat?.permanent?.ownCard.id.isEmpty == false
    }
    var identityFingerprint: String? {
        guard let value = chat?.permanent?.ownCard.id, !value.isEmpty else {
            return nil
        }
        let characters = Array(value.uppercased().prefix(12))
        return stride(from: 0, to: characters.count, by: 4)
            .map { start in
                String(characters[start..<min(start + 4, characters.count)])
            }
            .joined(separator: " ")
    }
    func retryMessaging() {
        chat?.retireForDeletion()
        chat = nil
        prepareMessaging()
        updateApplicationState(isActive: active)
    }
    private func synchronizeProfile() {
        guard !deletingProfile, let own = LocalCardStore.shared.ownManifest, let chat, chat.isReady else { return }
        let avatar = LocalCardStore.shared.photo(own.body.photoHash)
        let profile = SpotchatProfile(name: own.body.name, bio: own.body.bio ?? "", avatar: avatar)
        if chat.profiles.own != profile { _ = chat.saveProfile(name: profile.name, bio: profile.bio, avatar: profile.avatar) }
    }
    func completedRegistration() {
        guard LocalCardStore.shared.ownManifest != nil else { return }
        authCodeViewModel.restoreLocalProfile()
        needsSecuritySetup = false
        isRegistered = true
        UserDefaults.standard.set(true, forKey: Keys.isReg.rawValue)
        isScaning = true
        UserDefaults.standard.set(true, forKey: Keys.isScaning.rawValue)

        // The security screens use a runtime whose Bluetooth managers are
        // deliberately never created. Rebuild it after registration so the
        // first live session follows the same clean startup path as a normal
        // app launch instead of depending on a background/foreground cycle.
        chat = nil
        prepareMessaging()
        synchronizeProfile()
        updateApplicationState(isActive: active)
    }

    @discardableResult
    func prepareRestoredProfileForSecurity() -> Bool {
        guard !isRegistered, !deletingProfile else { return false }
        LocalCardStore.shared.reloadFromDisk()
        guard LocalCardStore.shared.ownManifest != nil else { return false }
        UserDefaults.standard.set(false, forKey: Keys.isReg.rawValue)
        authCodeViewModel.restoreLocalProfile()
        profilePhotoViewModel.loadPhotoIfNeeded()
        needsSecuritySetup = true
        return prepareRegistrationSecurity()
    }
    func setScanning(_ enabled: Bool) {
        isScaning = enabled && isRegistered
        UserDefaults.standard.set(isScaning, forKey: Keys.isScaning.rawValue)
        chat?.setBluetoothEnabled(
            isScaning && !ShumAppLock.shared.isLocked
        )
    }
    func refreshSession() async {
        authCodeViewModel.restoreLocalProfile(); profilePhotoViewModel.loadPhotoIfNeeded()
        synchronizeProfile()
    }
    func handleInvitationURL(_ url: URL) {
        guard isRegistered,
              LocalCardStore.shared.ownManifest != nil,
              chat?.isReady == true else {
            invitation = nil
            invitationError = "Сначала завершите регистрацию в Shum: получите ключи и создайте свой профиль. Затем откройте контакт ещё раз."
            return
        }

        do {
            switch try SpotchatInvitationPayload.parse(url) {
            case .card(let card):
                invitationError = nil
                invitation = card
            case .locator(let locator):
                guard let chat else { throw SpotchatFailure.unavailableIdentity }
                invitationError = nil
                chat.resolveContact(locator) { [weak self] result in
                    switch result {
                    case .success(let card):
                        self?.invitation = card
                    case .failure(let error):
                        self?.invitationError = error.localizedDescription
                    }
                }
            }
        } catch {
            invitationError = error.localizedDescription
        }
    }
    func deleteAccount() async throws {
        try deletion.begin()
        deletingProfile = true
        chat?.retireForDeletion(); chat = nil
        finishDeletion()
        if deletingProfile { throw SpotchatFailure.storage }
    }
    func finishDeletion() {
        do {
            try deletion.finish()
            try LocalCardStore.shared.reset()
            AccountSessionGeneration.shared.advance()
            peopleViewModel.resetAccountScopedState()
            authCodeViewModel.clearProfile(); profilePhotoViewModel.resetAccountScopedState()
            SavedPeopleStateStore.shared.removeAll(); QuickActionsSettingsStore.shared.reset()
            ShumAppLock.shared.reset()
            ShumAppearanceStore.shared.resetToClassic()
            try deletion.allowNewProfile()
            isRegistered = false; needsSecuritySetup = false
            isScaning = false; authenticationFlowID = UUID()
            deletionError = nil; deletingProfile = false
        } catch { deletionError = "Удаление не завершено. Разблокируйте iPhone и повторите. Обмен сообщениями остановлен." }
    }
    func updateApplicationState(isActive: Bool) {
        active = isActive
        guard !deletingProfile, isRegistered, let chat else { return }
        let hasCompletedLogin = !ShumAppLock.shared.isLocked
        chat.setBluetoothEnabled(isScaning && hasCompletedLogin)
        chat.setAppActive(isActive && hasCompletedLogin)
        if isActive && hasCompletedLogin { chat.start() }
    }
}
