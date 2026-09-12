import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    @Published var isRegistered = false
    @Published var authenticationFlowID = UUID()
    @Published var hasCompletedInitialSessionRefresh = true
    @Published var nearbyNotificationNavigationRequest = UUID()
    @Published var showSplash = true
    @Published var isScaning = false
    let chat = ShumChatRuntime()
    let authCodeViewModel: LocalProfileViewModel
    let peopleViewModel: PeopleViewModel
    let profilePhotoViewModel: ProfilePhotoViewModel
    private var photoObserver: NSObjectProtocol?

    init() {
        // Import only what is already on this phone. Never contact the old API.
        let store = LocalCardStore.shared
        let defaults = UserDefaults.standard
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-ShumPreview"), store.ownManifest == nil {
            _ = try? store.saveOwn(name: "Руслан", username: "ruslan", bio: "Пробую Shum", photo: nil)
        }
        #endif
        if store.ownManifest == nil, defaults.bool(forKey: Keys.isReg.rawValue),
           let name = defaults.string(forKey: Keys.localNameKey.rawValue),
           let username = defaults.string(forKey: Keys.usernameKey.rawValue) {
            let photo = ProfileImageStorage.load().flatMap { try? LocalCardPhoto.prepare($0) }
            _ = try? store.saveOwn(name: name, username: username,
                bio: defaults.string(forKey: Keys.bioKey.rawValue), photo: photo)
        }
        authCodeViewModel = LocalProfileViewModel()
        profilePhotoViewModel = ProfilePhotoViewModel()
        peopleViewModel = PeopleViewModel(bleManager: ShumInactiveCardRadio())
        isRegistered = store.ownManifest != nil
        if isRegistered {
            for key in ["shum.auth.access-token", "shum.auth.refresh-token",
                        "shum.auth.apple-primary-session-v1", "shum.auth.reset-pending-v1"] {
                try? KeychainStore.shared.remove(key)
            }
        }
        isScaning = isRegistered && defaults.bool(forKey: Keys.isScaning.rawValue)
        if let id = authCodeViewModel.shumID {
            defaults.set(id.uuidString, forKey: Keys.shumIDKey.rawValue)
        }
        AppNotificationRouter.shared.configure { [weak self] in self?.nearbyNotificationNavigationRequest = UUID() }
        photoObserver = NotificationCenter.default.addObserver(forName: .localCardChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.authCodeViewModel.restoreLocalProfile()
                self.chat.configure(name: self.authCodeViewModel.localName ?? "Гость", enabled: self.isScaning,
                    active: UIApplication.shared.applicationState == .active)
            }
        }
    }
    deinit { if let photoObserver { NotificationCenter.default.removeObserver(photoObserver) } }
    func start() -> AnyView {
        AnyView(AppCoordinatorView().environmentObject(self)
            .environmentObject(authCodeViewModel).environmentObject(peopleViewModel).environmentObject(chat))
    }
    func completedRegistration() {
        guard LocalCardStore.shared.ownManifest != nil else { return }
        authCodeViewModel.restoreLocalProfile(); isRegistered = true
        UserDefaults.standard.set(true, forKey: Keys.isReg.rawValue)
        setScanning(true); updateApplicationState(isActive: true)
    }
    func setScanning(_ enabled: Bool) {
        isScaning = enabled && isRegistered
        UserDefaults.standard.set(isScaning, forKey: Keys.isScaning.rawValue)
        chat.configure(name: authCodeViewModel.localName ?? "Гость", enabled: isScaning, active: true)
    }
    func refreshSession() async {
        authCodeViewModel.restoreLocalProfile(); profilePhotoViewModel.loadPhotoIfNeeded()
    }
    func deleteAccount() async throws {
        setScanning(false)
        try chat.reset()
        try LocalCardStore.shared.reset()
        AccountSessionGeneration.shared.advance()
        peopleViewModel.resetAccountScopedState()
        authCodeViewModel.clearProfile(); profilePhotoViewModel.resetAccountScopedState()
        SavedPeopleStateStore.shared.removeAll(); QuickActionsSettingsStore.shared.reset()
        for key in [Keys.isReg, .shumIDKey, .localNameKey, .usernameKey, .bioKey, .photoS3URLKey] {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        isRegistered = false; authenticationFlowID = UUID()
    }
    func updateApplicationState(isActive: Bool) {
        chat.configure(name: authCodeViewModel.localName ?? "Гость", enabled: isRegistered && isScaning, active: isActive)
    }
}
