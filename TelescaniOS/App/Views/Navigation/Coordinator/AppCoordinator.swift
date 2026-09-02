import SwiftUI

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    private let regKey = Keys.isReg.rawValue
    private let scanningKey = Keys.isScaning.rawValue
    private let authSession: AuthSessionStore
    private let sessionValidator: SessionValidator
    private let logoutAction: @MainActor (String) async throws -> Void
    private let bluetoothReset: @MainActor () -> Void
    private var isValidatingSession = false
    private var hasStartedInitialSessionRefresh = false
    private var sessionGeneration = UUID()

    @Published var isRegistered: Bool
    @Published private(set) var isAuthenticated: Bool
    @Published private(set) var authenticationFlowID = UUID()
    @Published private(set) var hasCompletedInitialSessionRefresh = false
    @Published private(set) var nearbyNotificationNavigationRequest = UUID()
    @Published var showSplash = true
    @Published var isScaning: Bool

    let authCodeViewModel: CodeViewModel
    let peopleViewModel: PeopleViewModel
    let profilePhotoViewModel: ProfilePhotoViewModel

    init(
        sessionValidator: SessionValidator? = nil,
        authSession: AuthSessionStore = .shared,
        authCodeViewModel: CodeViewModel? = nil,
        peopleViewModel: PeopleViewModel? = nil,
        profilePhotoViewModel: ProfilePhotoViewModel? = nil,
        primarySessionRequired: Bool? = nil,
        logoutAction: @escaping @MainActor (String) async throws -> Void = {
            try await FetchService.fetch.logoutCurrentSession(accessToken: $0)
        },
        bluetoothReset: @escaping @MainActor () -> Void = {
            BLEManager.shared.reset()
        }
    ) {
        self.authSession = authSession
        self.sessionValidator = sessionValidator ?? SessionValidator()
        self.logoutAction = logoutAction
        self.bluetoothReset = bluetoothReset
        self.authCodeViewModel = authCodeViewModel ?? CodeViewModel()
        self.peopleViewModel = peopleViewModel ?? PeopleViewModel()
        self.profilePhotoViewModel = profilePhotoViewModel
            ?? ProfilePhotoViewModel()
        let locallyRegistered = UserDefaults.standard.bool(forKey: regKey)
        let hasPrimarySession = authSession.hasPrimarySession
        #if TELESCAN_PERSONAL_TEAM
        let requiresPrimarySession = primarySessionRequired ?? false
        let hasTokens = authSession.hasTokens
        let hasUsableAccountSession = requiresPrimarySession
            ? hasPrimarySession
            : hasTokens
        isAuthenticated = AppConfig.skipRegistration || hasTokens
        isRegistered = AppConfig.skipRegistration
            || (locallyRegistered && hasTokens)
        #else
        let hasUsableAccountSession = hasPrimarySession
        isAuthenticated = AppConfig.skipRegistration || hasPrimarySession
        isRegistered = AppConfig.skipRegistration
            || (locallyRegistered && hasPrimarySession)
        #endif
        isScaning = UserDefaults.standard.bool(forKey: scanningKey)
        self.authCodeViewModel.restoreLocalProfile()
        if !hasUsableAccountSession,
           !AppConfig.skipRegistration {
            resetAccountScopedSession()
        }

        AppNotificationRouter.shared.configure { [weak self] in
            self?.nearbyNotificationNavigationRequest = UUID()
        }
    }

    func start() -> AnyView {
        AnyView(
            AppCoordinatorView()
                .environmentObject(self)
                .environmentObject(authCodeViewModel)
                .environmentObject(peopleViewModel)
                .task {
                    await self.refreshInitialSession()
                }
        )
    }

    private func refreshInitialSession() async {
        guard !hasStartedInitialSessionRefresh else { return }
        hasStartedInitialSessionRefresh = true

        await refreshSession()
        hasCompletedInitialSessionRefresh = true
    }

    func completedRegistration() {
        guard AppConfig.skipRegistration || authSession.hasTokens else {
            resetAccountScopedSession()
            return
        }
        isAuthenticated = true
        isRegistered = true
        UserDefaults.standard.set(true, forKey: regKey)
        profilePhotoViewModel.loadPhotoFromURL(authCodeViewModel.photoS3URL)
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
        let credentials = authSession.credentials
        guard resetAccountScopedSession(
            ifCredentialGenerationMatches: credentials.generation
        ) else { return }
        guard let accessToken = credentials.accessToken else { return }
        do {
            try await logoutAction(accessToken)
        } catch {
            // The local logout is already complete. Remote revocation is
            // best-effort because a response may be lost after the delete.
        }
    }

    func deleteAccount() async throws {
        let generation = sessionGeneration
        do {
            try await FetchService.fetch.deleteAccount()
            guard generation == sessionGeneration else { return }
            resetAccountScopedSession()
        } catch APIClientError.unauthenticated {
            guard generation == sessionGeneration else { return }
            resetAccountScopedSession()
        } catch APIClientError.httpStatus(let status) where status == 404 {
            guard generation == sessionGeneration else { return }
            resetAccountScopedSession()
        }
    }

    func refreshSession() async {
        guard isAuthenticated, authSession.hasTokens, !isValidatingSession else {
            return
        }
        let generation = sessionGeneration
        isValidatingSession = true
        defer {
            if generation == sessionGeneration {
                isValidatingSession = false
            }
        }

        let validation = await sessionValidator.validate()
        guard generation == sessionGeneration else { return }
        switch validation {
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
            resetAccountScopedSession()
        case .unavailable:
            break
        }
    }

    @discardableResult
    private func resetAccountScopedSession(
        ifCredentialGenerationMatches expectedGeneration: UUID? = nil
    ) -> Bool {
        if let expectedGeneration {
            guard authSession.beginLocalReset(
                ifGenerationMatches: expectedGeneration
            ) else { return false }
        } else {
            authSession.clearTokens()
        }
        AccountSessionGeneration.shared.advance()
        sessionGeneration = UUID()
        isValidatingSession = false
        peopleViewModel.resetAccountScopedState()
        bluetoothReset()
        ProfileCache.clear()
        authCodeViewModel.clearProfile()
        profilePhotoViewModel.resetAccountScopedState()
        SavedPeopleStateStore.shared.removeAll()
        QuickActionsSettingsStore.shared.reset()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        isScaning = false
        isAuthenticated = false
        isRegistered = false
        authenticationFlowID = UUID()
        return true
    }

    func updateApplicationState(isActive: Bool) {
        guard isRegistered,
              AppConfig.skipRegistration || authCodeViewModel.isUsernameConfirmed else {
            peopleViewModel.stopAllBluetoothActivity()
            return
        }
        peopleViewModel.reconcileBluetoothState(
            isActive: isActive,
            scanningEnabled: isScaning
        )
        guard isActive, isScaning else { return }
        peopleViewModel.toggleScanning(true)
        if let id = authCodeViewModel.telescanID {
            peopleViewModel.startAdvertising(telescanID: id)
        }
    }
}
