import SwiftUI
import Kingfisher

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    private let regKey = Keys.isReg.rawValue
    private let scanningKey = Keys.isScaning.rawValue
    private let pendingLogoutAllKey = Keys.pendingLogoutAllConfirmation.rawValue
    private let authSession = AuthSessionStore.shared
    private var logoutAllPollingTask: Task<Void, Never>?

    @Published var isRegistered: Bool
    @Published var showSplash = true
    @Published var isScaning: Bool

    let authCodeViewModel = CodeViewModel()
    let peopleViewModel = PeopleViewModel()

    init() {
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
                    self.resumePendingLogoutAllIfNeeded()
                }
        )
    }

    func completedRegistration() {
        isRegistered = true
        UserDefaults.standard.set(true, forKey: regKey)
    }

    func logoutCurrentSession() async throws {
        try await FetchService.fetch.logoutCurrentSession()
        clearLocalSession()
    }

    func requestLogoutAll() async throws {
        let confirmation = try await FetchService.fetch.requestLogoutAll()
        UserDefaults.standard.set(
            confirmation.confirmationId.uuidString.lowercased(),
            forKey: pendingLogoutAllKey
        )
        startLogoutAllPolling(confirmation.confirmationId)
    }

    func resumePendingLogoutAllIfNeeded() {
        guard isRegistered,
              logoutAllPollingTask == nil,
              let value = UserDefaults.standard.string(forKey: pendingLogoutAllKey),
              let confirmationID = UUID(uuidString: value) else { return }
        startLogoutAllPolling(confirmationID)
    }

    func deleteAccount() async throws {
        try await FetchService.fetch.deleteAccount()
        clearLocalSession()
    }

    private func clearLocalSession() {
        logoutAllPollingTask?.cancel()
        logoutAllPollingTask = nil
        peopleViewModel.stopAllBluetoothActivity()
        BLEManager.shared.reset()
        authSession.clearTokens()
        ProfileImageStorage.delete()
        URLCache.shared.removeAllCachedResponses()
        ImageCache.default.clearMemoryCache()
        ImageCache.default.clearDiskCache()
        authCodeViewModel.clearProfile()
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        isScaning = false
        isRegistered = false
    }

    private func startLogoutAllPolling(_ confirmationID: UUID) {
        logoutAllPollingTask?.cancel()
        let poller = LogoutAllStatusPoller()
        logoutAllPollingTask = Task { [weak self] in
            let resolution = await poller.wait(for: confirmationID)
            guard !Task.isCancelled, let resolution, let self else { return }
            logoutAllPollingTask = nil
            UserDefaults.standard.removeObject(forKey: pendingLogoutAllKey)
            if resolution == .confirmed {
                clearLocalSession()
            }
        }
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
