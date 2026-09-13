import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    @Published var isRegistered = false
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
        isRegistered = store.ownManifest != nil && !previewsOnboarding
        isScaning = isRegistered && UserDefaults.standard.bool(forKey: Keys.isScaning.rawValue)
        if deletion.hasDeletion {
            deletingProfile = true
            finishDeletion()
        } else if isRegistered { prepareMessaging() }
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
        let model = SpotchatRuntime.live()
        model.deleteProfileHandler = { [weak self] in
            Task { @MainActor in try? await self?.deleteAccount() }
        }
        model.setBluetoothEnabled(isScaning)
        model.setAppActive(false)
        chat = model
        synchronizeProfile()
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
        authCodeViewModel.restoreLocalProfile(); isRegistered = true
        UserDefaults.standard.set(true, forKey: Keys.isReg.rawValue)
        isScaning = true
        UserDefaults.standard.set(true, forKey: Keys.isScaning.rawValue)
        if chat == nil { prepareMessaging() }
        updateApplicationState(isActive: true)
    }
    func setScanning(_ enabled: Bool) {
        isScaning = enabled && isRegistered
        UserDefaults.standard.set(isScaning, forKey: Keys.isScaning.rawValue)
        chat?.setBluetoothEnabled(isScaning)
    }
    func refreshSession() async {
        authCodeViewModel.restoreLocalProfile(); profilePhotoViewModel.loadPhotoIfNeeded()
        synchronizeProfile()
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
            try deletion.allowNewProfile()
            isRegistered = false; isScaning = false; authenticationFlowID = UUID()
            deletionError = nil; deletingProfile = false
        } catch { deletionError = "Удаление не завершено. Разблокируйте iPhone и повторите. Обмен сообщениями остановлен." }
    }
    func updateApplicationState(isActive: Bool) {
        active = isActive
        guard !deletingProfile, isRegistered, let chat else { return }
        chat.setAppActive(isActive)
        if isActive { chat.start() }
    }
}
