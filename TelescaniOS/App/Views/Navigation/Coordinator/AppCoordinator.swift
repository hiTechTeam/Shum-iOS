import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    private let regKey = Keys.isReg.rawValue
    private let scanningKey = Keys.isScaning.rawValue
    private let authSession = AuthSessionStore.shared
    private let sessionValidator: SessionValidator
    private var isValidatingSession = false

    @Published var isRegistered: Bool
    @Published private(set) var isAuthenticated: Bool
    @Published private(set) var authenticationFlowID = UUID()
    @Published var showSplash = true
    @Published var isScaning: Bool

    let authCodeViewModel = CodeViewModel()
    let peopleViewModel = PeopleViewModel()

    init(sessionValidator: SessionValidator? = nil) {
        self.sessionValidator = sessionValidator ?? SessionValidator()
        let locallyRegistered = UserDefaults.standard.bool(forKey: regKey)
        let hasTokens = AuthSessionStore.shared.hasTokens
        let hasPrimarySession = AuthSessionStore.shared.hasPrimarySession
        let hasLegacySession = hasTokens && !hasPrimarySession
        #if TELESCAN_PERSONAL_TEAM
        isAuthenticated = AppConfig.skipRegistration || hasTokens
        isRegistered = AppConfig.skipRegistration
            || (locallyRegistered && hasTokens)
        #else
        isAuthenticated = AppConfig.skipRegistration || hasPrimarySession
        isRegistered = AppConfig.skipRegistration
            || (locallyRegistered && hasPrimarySession)
        #endif
        isScaning = UserDefaults.standard.bool(forKey: scanningKey)
        authCodeViewModel.restoreLocalProfile()
        #if !TELESCAN_PERSONAL_TEAM
        if hasLegacySession || locallyRegistered && !hasPrimarySession,
           !AppConfig.skipRegistration {
            clearLocalSession()
        }
        #endif
    }

    func start() -> AnyView {
        AnyView(
            AppCoordinatorView()
                .environmentObject(self)
                .environmentObject(authCodeViewModel)
                .environmentObject(peopleViewModel)
                .task {
                    await self.refreshSession()
                }
        )
    }

    func completedRegistration() {
        guard AppConfig.skipRegistration || authSession.hasTokens else {
            clearLocalSession()
            return
        }
        isAuthenticated = true
        isRegistered = true
        UserDefaults.standard.set(true, forKey: regKey)
        setScanning(true)
        updateApplicationState(isActive: true)
    }

    func completedAppleSignIn(profile: TelescanProfileResponse) {
        authCodeViewModel.applyProfile(profile)
        isAuthenticated = true
        if profile.isTelegramLinked {
            completedRegistration()
        } else {
            isRegistered = false
            UserDefaults.standard.set(false, forKey: regKey)
        }
    }

    func setScanning(_ enabled: Bool) {
        isScaning = enabled
        UserDefaults.standard.set(enabled, forKey: scanningKey)

        if enabled {
            peopleViewModel.toggleScanning(true)
            if let id = authCodeViewModel.telescanID {
                peopleViewModel.startAdvertising(telescanID: id)
            }
        } else {
            peopleViewModel.stopAllBluetoothActivity()
        }
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
        guard isAuthenticated, authSession.hasTokens, !isValidatingSession else {
            return
        }
        isValidatingSession = true
        defer { isValidatingSession = false }

        switch await sessionValidator.validate() {
        case .active(let profile):
            authCodeViewModel.applyProfile(profile)
            if !isRegistered {
                completedRegistration()
            }
            if isScaning {
                peopleViewModel.startAdvertising(
                    telescanID: profile.telescanId
                )
            }
        case .telegramLinkRequired(let profile):
            authCodeViewModel.applyProfile(profile)
            isRegistered = false
            UserDefaults.standard.set(false, forKey: regKey)
        case .invalid:
            clearLocalSession()
        case .unavailable:
            break
        }
    }

    private func clearLocalSession() {
        peopleViewModel.stopAllBluetoothActivity()
        peopleViewModel.clearBlockedProfileCache()
        peopleViewModel.clearEncounterHistory()
        BLEManager.shared.reset()
        authSession.clearTokens()
        ProfileCache.clear()
        authCodeViewModel.clearProfile()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        isScaning = false
        isAuthenticated = false
        isRegistered = false
        authenticationFlowID = UUID()
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
