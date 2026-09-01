import Foundation

struct AuthSessionCredentials: Sendable {
    let generation: UUID
    let accessToken: String?
    let refreshToken: String?
}

final class AuthSessionStore: @unchecked Sendable {
    static let shared = AuthSessionStore()

    private enum Key {
        static let accessToken = "telescan.auth.access-token"
        static let refreshToken = "telescan.auth.refresh-token"
        static let primarySession = "telescan.auth.apple-primary-session-v1"
        static let resetPending = "telescan.auth.reset-pending-v1"
    }

    private let store: SecureStoring
    private let deviceIdentity: DeviceIdentity
    private let resetDefaults: UserDefaults
    private let lock = NSLock()
    private var generation = UUID()

    init(
        store: SecureStoring = KeychainStore.shared,
        resetDefaults: UserDefaults? = nil
    ) {
        self.store = store
        self.deviceIdentity = DeviceIdentity(store: store)
        self.resetDefaults = resetDefaults ?? Self.makeResetDefaults()
    }

    var accessToken: String? {
        withLock {
            guard !isResetPending else { return nil }
            return string(for: Key.accessToken)
        }
    }

    var refreshToken: String? {
        withLock {
            guard !isResetPending else { return nil }
            return string(for: Key.refreshToken)
        }
    }

    var credentialGeneration: UUID {
        withLock { generation }
    }

    var credentials: AuthSessionCredentials {
        withLock {
            guard !isResetPending else {
                return AuthSessionCredentials(
                    generation: generation,
                    accessToken: nil,
                    refreshToken: nil
                )
            }
            return AuthSessionCredentials(
                generation: generation,
                accessToken: string(for: Key.accessToken),
                refreshToken: string(for: Key.refreshToken)
            )
        }
    }

    var hasTokens: Bool {
        let credentials = credentials
        return credentials.accessToken != nil && credentials.refreshToken != nil
    }

    var hasPrimarySession: Bool {
        withLock {
            !isResetPending
                && string(for: Key.accessToken) != nil
                && string(for: Key.refreshToken) != nil
                && string(for: Key.primarySession) == "apple-v1"
        }
    }

    var hasPendingReset: Bool {
        withLock { isResetPending }
    }

    func installationDeviceID() throws -> UUID {
        try withLock { try deviceIdentity.value() }
    }

    func save(_ tokens: TokenResponse) throws {
        try withLock {
            do {
                try completePendingResetIfNeeded()
                try saveTokens(tokens)
            } catch {
                clearTokensAndAdvanceGeneration()
                throw error
            }
        }
    }

    @discardableResult
    func save(
        _ tokens: TokenResponse,
        ifGenerationMatches expectedGeneration: UUID
    ) throws -> Bool {
        try withLock {
            guard generation == expectedGeneration else { return false }
            do {
                try completePendingResetIfNeeded()
                try saveTokens(tokens)
                return true
            } catch {
                clearTokensAndAdvanceGeneration()
                throw error
            }
        }
    }

    @discardableResult
    func saveAppleSession(
        _ tokens: TokenResponse,
        ifGenerationMatches expectedGeneration: UUID? = nil
    ) throws -> Bool {
        try withLock {
            guard expectedGeneration == nil
                    || generation == expectedGeneration else {
                return false
            }
            do {
                try completePendingResetIfNeeded()
                try saveTokens(tokens)
                try store.set(Data("apple-v1".utf8), for: Key.primarySession)
                generation = UUID()
                return true
            } catch {
                clearTokensAndAdvanceGeneration()
                throw error
            }
        }
    }

    @discardableResult
    func saveLegacySession(
        _ tokens: TokenResponse,
        ifGenerationMatches expectedGeneration: UUID? = nil
    ) throws -> Bool {
        try withLock {
            guard expectedGeneration == nil
                    || generation == expectedGeneration else {
                return false
            }
            do {
                try completePendingResetIfNeeded()
                try saveTokens(tokens)
                try store.remove(Key.primarySession)
                generation = UUID()
                return true
            } catch {
                clearTokensAndAdvanceGeneration()
                throw error
            }
        }
    }

    func saveAccessToken(_ token: String) throws {
        guard !token.isEmpty else { throw SecureStoreError.invalidData }
        try withLock {
            try completePendingResetIfNeeded()
            try store.set(Data(token.utf8), for: Key.accessToken)
        }
    }

    @discardableResult
    func saveAccessToken(
        _ token: String,
        ifGenerationMatches expectedGeneration: UUID
    ) throws -> Bool {
        guard !token.isEmpty else { throw SecureStoreError.invalidData }
        return try withLock {
            guard generation == expectedGeneration else { return false }
            try completePendingResetIfNeeded()
            try store.set(Data(token.utf8), for: Key.accessToken)
            return true
        }
    }

    @discardableResult
    func clearTokens() -> Bool {
        withLock {
            clearTokensAndAdvanceGeneration()
        }
    }

    @discardableResult
    func clearTokens(ifGenerationMatches expectedGeneration: UUID) -> Bool {
        withLock {
            guard generation == expectedGeneration else { return false }
            return clearTokensAndAdvanceGeneration()
        }
    }

    /// Atomically claims the current credential generation for a local
    /// account reset. A failed Keychain deletion remains fail-closed, but a
    /// stale operation cannot claim (and therefore cannot reset) a new login.
    @discardableResult
    func beginLocalReset(ifGenerationMatches expectedGeneration: UUID) -> Bool {
        withLock {
            guard generation == expectedGeneration else { return false }
            _ = clearTokensAndAdvanceGeneration()
            return true
        }
    }

    private func saveTokens(_ tokens: TokenResponse) throws {
        try store.set(Data(tokens.accessToken.utf8), for: Key.accessToken)
        try store.set(Data(tokens.refreshToken.utf8), for: Key.refreshToken)
    }

    @discardableResult
    private func clearTokensAndAdvanceGeneration() -> Bool {
        resetDefaults.set(true, forKey: Key.resetPending)
        resetDefaults.synchronize()
        generation = UUID()
        let cleared = removeCredentialsAndVerify()
        if cleared {
            resetDefaults.removeObject(forKey: Key.resetPending)
            resetDefaults.synchronize()
        }
        return cleared
    }

    private func completePendingResetIfNeeded() throws {
        guard isResetPending else { return }
        guard removeCredentialsAndVerify() else {
            throw SecureStoreError.resetIncomplete
        }
        resetDefaults.removeObject(forKey: Key.resetPending)
        resetDefaults.synchronize()
    }

    private func removeCredentialsAndVerify() -> Bool {
        var succeeded = true

        do {
            try store.set(
                Data("reset-pending-v1".utf8),
                for: Key.primarySession
            )
        } catch {
            succeeded = false
        }
        for key in [Key.accessToken, Key.refreshToken, Key.primarySession] {
            do {
                try store.remove(key)
            } catch {
                succeeded = false
            }
        }
        for key in [Key.accessToken, Key.refreshToken, Key.primarySession] {
            do {
                if try store.data(for: key) != nil {
                    succeeded = false
                }
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func string(for key: String) -> String? {
        guard let data = try? store.data(for: key),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private var isResetPending: Bool {
        resetDefaults.bool(forKey: Key.resetPending)
    }

    private static func makeResetDefaults() -> UserDefaults {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.telescan.auth"
        guard let defaults = UserDefaults(
            suiteName: "\(bundleID).auth-session-boundary"
        ) else {
            preconditionFailure("Unable to create the auth reset marker store")
        }
        return defaults
    }
}
