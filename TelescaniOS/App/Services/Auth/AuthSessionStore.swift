import Foundation

final class AuthSessionStore: @unchecked Sendable {
    static let shared = AuthSessionStore()

    private enum Key {
        static let accessToken = "telescan.auth.access-token"
        static let refreshToken = "telescan.auth.refresh-token"
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

    func clearTokens() {
        try? store.remove(Key.accessToken)
        try? store.remove(Key.refreshToken)
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
