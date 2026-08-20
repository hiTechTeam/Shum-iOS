import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    private let regKey = Keys.isReg.rawValue
    private let scanningKey = Keys.isScaning.rawValue
    private let authSession = AuthSessionStore.shared
    private let sessionValidator: SessionValidator
    private var isValidatingSession = false

    @Published var isRegistered: Bool
    @Published var showSplash = true
    @Published var isScaning: Bool

    let authCodeViewModel = CodeViewModel()
    let peopleViewModel = PeopleViewModel()

    init(sessionValidator: SessionValidator? = nil) {
        self.sessionValidator = sessionValidator ?? SessionValidator()
        let locallyRegistered = UserDefaults.standard.bool(forKey: regKey)
        isRegistered = AppConfig.skipRegistration
            || (locallyRegistered && AuthSessionStore.shared.hasTokens)
        isScaning = UserDefaults.standard.bool(forKey: scanningKey)
        authCodeViewModel.restoreLocalProfile()
        if locallyRegistered,
           !AuthSessionStore.shared.hasTokens,
           !AppConfig.skipRegistration {
            clearLocalSession()
        }
    }

    func start() -> AnyView {
        AnyView(
            AppCoordinatorView()
                .environmentObject(self)
                .environmentObject(authCodeViewModel)
                .environmentObject(peopleViewModel)
                .onAppear {
                    self.updateApplicationState(isActive: true)
                    Task {
                        await self.refreshSession()
                    }
                }
        )
    }

    func completedRegistration() {
        isRegistered = true
        UserDefaults.standard.set(true, forKey: regKey)
        updateApplicationState(isActive: true)
    }

    func logoutCurrentSession() async throws {
        do {
            try await FetchService.fetch.logoutCurrentSession()
            clearLocalSession()
        } catch APIClientError.unauthenticated {
            clearLocalSession()
        }
    }

    func deleteAccount() async throws {
        do {
            try await FetchService.fetch.deleteAccount()
            clearLocalSession()
        } catch APIClientError.unauthenticated {
            clearLocalSession()
        } catch APIClientError.httpStatus(let status) where status == 404 {
            clearLocalSession()
        }
    }

    func refreshSession() async {
        guard isRegistered, !isValidatingSession else { return }
        isValidatingSession = true
        defer { isValidatingSession = false }

        switch await sessionValidator.validate() {
        case .active(let profile):
            authCodeViewModel.applyProfile(profile)
            if isScaning {
                peopleViewModel.startAdvertising(
                    telescanID: profile.telescanId
                )
            }
        case .invalid:
            clearLocalSession()
        case .unavailable:
            break
        }
    }

    private func clearLocalSession() {
        peopleViewModel.stopAllBluetoothActivity()
        peopleViewModel.clearBlockedProfileCache()
        BLEManager.shared.reset()
        authSession.clearTokens()
        ProfileCache.clear()
        authCodeViewModel.clearProfile()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        isScaning = false
        isRegistered = false
    }

    func updateApplicationState(isActive: Bool) {
        guard isRegistered,
              AppConfig.skipRegistration || authCodeViewModel.isUsernameConfirmed else {
            peopleViewModel.stopAllBluetoothActivity()
            return
        }
        peopleViewModel.reconcileBluetoothState(isActive: isActive)
        guard isActive, isScaning else { return }
        peopleViewModel.toggleScanning(true)
        if let id = authCodeViewModel.telescanID {
            peopleViewModel.startAdvertising(telescanID: id)
        }
    }
}
