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
    }

    func start() -> AnyView {
        AnyView(
            AppCoordinatorView()
                .environmentObject(self)
                .environmentObject(authCodeViewModel)
                .environmentObject(peopleViewModel)
                .onAppear {
                    self.startScanningIfNeeded()
                    Task {
                        await self.refreshSession()
                    }
                }
        )
    }

    func completedRegistration() {
        isRegistered = true
        UserDefaults.standard.set(true, forKey: regKey)
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
        case .invalid:
            clearLocalSession()
        case .unavailable:
            break
        }
    }

    private func clearLocalSession() {
        peopleViewModel.stopAllBluetoothActivity()
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

    private func startScanningIfNeeded() {
        guard isRegistered, isScaning else { return }
        peopleViewModel.toggleScanning(true)
        if let value = UserDefaults.standard.string(forKey: Keys.telescanIDKey.rawValue),
           let id = UUID(uuidString: value) {
            peopleViewModel.startAdvertising(telescanID: id)
        }
    }
}
