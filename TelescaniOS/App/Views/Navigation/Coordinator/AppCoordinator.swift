//
//  AppCoordinator.swift
//  Telescan
//
//  Application coordinator. Handles app startup, registration, login/logout, and scanning state management.
//

import SwiftUI
import Kingfisher

@MainActor
final class AppCoordinator: ObservableObject, AppCoordinatorProtocol {
    
    // MARK: - Constants
    private let regKey: String = Keys.isReg.rawValue
    private let isScaningKey: String = Keys.isScaning.rawValue
    
    // MARK: - Published Properties
    @Published var isRegistered: Bool
    @Published var showSplash: Bool = true
    @Published var isScaning: Bool
    
    // MARK: - ViewModels
    let authCodeViewModel = CodeViewModel()
    let peopleViewModel = PeopleViewModel()
    
    // MARK: - Initialization
    init() {
        self.isRegistered = UserDefaults.standard.bool(forKey: regKey)
        self.isScaning = UserDefaults.standard.bool(forKey: isScaningKey)
    }
    
    // MARK: - Coordinator Methods
    /// Starts the app and returns the main view
    func start() -> AnyView {
        AnyView(
            AppCoordinatorView()
                .environmentObject(self)
                .environmentObject(authCodeViewModel)
                .environmentObject(peopleViewModel)
                .onAppear {
                    self.startScaningIfNeeded()
                }
        )
    }
    
    /// Completes user registration
    func completedRegistration() {
        isRegistered = true
        UserDefaults.standard.set(true, forKey: regKey)
    }
    
    /// Logs out the user
    func logout() {
        isRegistered = false
        UserDefaults.standard.set(false, forKey: regKey)
    }

    /// Permanently deletes the remote profile before clearing local data.
    func deleteAccount() async throws {
        guard let telegramID = UserDefaults.standard.object(
            forKey: Keys.tgIdKey.rawValue
        ) as? Int else {
            throw AccountDeletionError.missingTelegramID
        }

        guard let code = UserDefaults.standard.string(
            forKey: Keys.cleanCodeKey.rawValue
        ), !code.isEmpty else {
            throw AccountDeletionError.missingCode
        }

        try await FetchService.fetch.deleteAccount(
            tgID: telegramID,
            code: code
        )

        peopleViewModel.stopAllBluetoothActivity()
        BLEManager.shared.reset()
        ProfileImageStorage.delete()
        URLCache.shared.removeAllCachedResponses()
        ImageCache.default.clearMemoryCache()
        await ImageCache.default.clearDiskCache()
        authCodeViewModel.clearProfile()

        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(
                forName: bundleID
            )
        }

        isScaning = false
        isRegistered = false
    }
    
    // MARK: - Private Methods
    /// Starts scanning and BLE advertising if conditions are met
    private func startScaningIfNeeded() {
        guard isRegistered, isScaning else { return }
        
        peopleViewModel.toggleScanning(true)
        
        if let telegramID = UserDefaults.standard.object(forKey: Keys.tgIdKey.rawValue) as? Int {
            BLEManager.shared.startAdvertising(id: String(telegramID))
        }
    }
}

enum AccountDeletionError: Error {
    case missingTelegramID
    case missingCode
}
