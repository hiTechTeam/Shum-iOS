import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    @Published var isRegistered = false
    @Published var authenticationFlowID = UUID()
    @Published var hasCompletedInitialSessionRefresh = true
    @Published var nearbyNotificationNavigationRequest = UUID()
    @Published var showSplash = true
    @Published var isScaning = false
    let authCodeViewModel: LocalProfileViewModel
    let peopleViewModel: PeopleViewModel
    let profilePhotoViewModel: ProfilePhotoViewModel
    private var photoObserver: NSObjectProtocol?

    init() {
        // Import only what is already on this phone. Never contact the old API.
        let store = LocalCardStore.shared
        let defaults = UserDefaults.standard
        if store.ownManifest == nil, defaults.bool(forKey: Keys.isReg.rawValue),
           let name = defaults.string(forKey: Keys.tgNameKey.rawValue),
           let username = defaults.string(forKey: Keys.usernameKey.rawValue) {
            let photo = ProfileImageStorage.load().flatMap { try? LocalCardPhoto.prepare($0) }
            _ = try? store.saveOwn(name: name, username: username,
                bio: defaults.string(forKey: Keys.bioKey.rawValue), photo: photo)
        }
        authCodeViewModel = LocalProfileViewModel()
        profilePhotoViewModel = ProfilePhotoViewModel()
        peopleViewModel = PeopleViewModel()
        isRegistered = store.ownManifest != nil
        if isRegistered {
            for key in ["telescan.auth.access-token", "telescan.auth.refresh-token",
                        "telescan.auth.apple-primary-session-v1", "telescan.auth.reset-pending-v1"] {
                try? KeychainStore.shared.remove(key)
            }
        }
        isScaning = isRegistered && defaults.bool(forKey: Keys.isScaning.rawValue)
        if let id = authCodeViewModel.telescanID {
            defaults.set(id.uuidString, forKey: Keys.telescanIDKey.rawValue)
        }
        AppNotificationRouter.shared.configure { [weak self] in self?.nearbyNotificationNavigationRequest = UUID() }
        photoObserver = NotificationCenter.default.addObserver(forName: .localCardChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.authCodeViewModel.restoreLocalProfile() }
        }
    }
    deinit { if let photoObserver { NotificationCenter.default.removeObserver(photoObserver) } }
    func start() -> AnyView {
        AnyView(AppCoordinatorView().environmentObject(self)
            .environmentObject(authCodeViewModel).environmentObject(peopleViewModel))
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
        if isScaning, let id = authCodeViewModel.telescanID {
            peopleViewModel.toggleScanning(true); peopleViewModel.startAdvertising(telescanID: id)
        } else { peopleViewModel.stopAllBluetoothActivity() }
    }
    func refreshSession() async {
        authCodeViewModel.restoreLocalProfile(); profilePhotoViewModel.loadPhotoIfNeeded()
    }
    func deleteAccount() async throws {
        setScanning(false)
        try LocalCardStore.shared.reset()
        AccountSessionGeneration.shared.advance()
        peopleViewModel.resetAccountScopedState(); BLEManager.shared.reset()
        authCodeViewModel.clearProfile(); profilePhotoViewModel.resetAccountScopedState()
        SavedPeopleStateStore.shared.removeAll(); QuickActionsSettingsStore.shared.reset()
        for key in [Keys.isReg, .telescanIDKey, .tgNameKey, .usernameKey, .bioKey, .photoS3URLKey] {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
        isRegistered = false; authenticationFlowID = UUID()
    }
    func updateApplicationState(isActive: Bool) {
        guard isRegistered else { peopleViewModel.stopAllBluetoothActivity(); return }
        peopleViewModel.reconcileBluetoothState(isActive: isActive, scanningEnabled: isScaning)
        if isActive, isScaning, let id = authCodeViewModel.telescanID {
            peopleViewModel.toggleScanning(true); peopleViewModel.startAdvertising(telescanID: id)
        }
    }
}
