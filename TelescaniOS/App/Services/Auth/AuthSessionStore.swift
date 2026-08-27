import Foundation

final class AuthSessionStore: @unchecked Sendable {
    static let shared = AuthSessionStore()

    private enum Key {
        static let accessToken = "telescan.auth.access-token"
        static let refreshToken = "telescan.auth.refresh-token"
        static let primarySession = "telescan.auth.apple-primary-session-v1"
    }

    private let store: SecureStoring
    private let deviceIdentity: DeviceIdentity

    init(store: SecureStoring = KeychainStore.shared) {
        self.store = store
        self.deviceIdentity = DeviceIdentity(store: store)
    }

    var accessToken: String? {
        string(for: Key.accessToken)
    }

    var refreshToken: String? {
        string(for: Key.refreshToken)
    }

    var hasTokens: Bool {
        accessToken != nil && refreshToken != nil
    }

    var hasPrimarySession: Bool {
        hasTokens && string(for: Key.primarySession) == "apple-v1"
    }

    func installationDeviceID() throws -> UUID {
        try deviceIdentity.value()
    }

    func save(_ tokens: TokenResponse) throws {
        do {
            try store.set(Data(tokens.accessToken.utf8), for: Key.accessToken)
            try store.set(Data(tokens.refreshToken.utf8), for: Key.refreshToken)
        } catch {
            clearTokens()
            throw error
        }
    }

    func saveAppleSession(_ tokens: TokenResponse) throws {
        do {
            try save(tokens)
            try store.set(Data("apple-v1".utf8), for: Key.primarySession)
        } catch {
            clearTokens()
            throw error
        }
    }

    func saveLegacySession(_ tokens: TokenResponse) throws {
        do {
            try save(tokens)
            try store.remove(Key.primarySession)
        } catch {
            clearTokens()
            throw error
        }
    }

    func saveAccessToken(_ token: String) throws {
        guard !token.isEmpty else { throw SecureStoreError.invalidData }
        try store.set(Data(token.utf8), for: Key.accessToken)
    }

    func clearTokens() {
        try? store.remove(Key.accessToken)
        try? store.remove(Key.refreshToken)
        try? store.remove(Key.primarySession)
    }

    private func string(for key: String) -> String? {
        guard let data = try? store.data(for: key),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
