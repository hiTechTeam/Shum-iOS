import Foundation
import Testing
@testable import Telescan

@Suite("Authenticated API client", .serialized)
struct FetchServiceTests {
    @Test("A complete code links immediately and exposes the username")
    @MainActor
    func completeCodeLinksImmediately() async {
        clearStoredProfile()
        defer { clearStoredProfile() }
        let profileID = UUID()
        let viewModel = CodeViewModel { code in
            #expect(code == "AB12CD34")
            return LinkDeviceResponse(
                tokens: TokenResponse(
                    accessToken: "access",
                    refreshToken: "refresh",
                    tokenType: "bearer",
                    expiresIn: 900
                ),
                profile: TelescanProfileResponse(
                    telescanId: profileID,
                    name: "Ada",
                    username: "ada",
                    photoUrl: nil
                )
            )
        }
        viewModel.tmpCode = "ab12cd34"
        viewModel.checkCode(viewModel.tmpCode)
        await waitForCodeCheck(viewModel)

        #expect(viewModel.codeStatus == true)
        #expect(viewModel.tmpTgUsername == "@ada")
        #expect(viewModel.telescanID == profileID)
        #expect(await viewModel.confirmCode())
        #expect(UserDefaults.standard.object(forKey: "cleanCode") == nil)
        #expect(UserDefaults.standard.object(forKey: "userCode") == nil)
    }

    @Test("A rejected complete code exposes the visual error state")
    @MainActor
    func rejectedCodeShowsError() async {
        struct RejectedCode: Error { }
        let viewModel = CodeViewModel { _ in throw RejectedCode() }

        viewModel.tmpCode = "BADCODE1"
        viewModel.checkCode(viewModel.tmpCode)
        await waitForCodeCheck(viewModel)

        #expect(viewModel.codeStatus == false)
        #expect(viewModel.tmpTgUsername == nil)
        #expect(await !viewModel.confirmCode())
    }

    @Test("Session validation refreshes the current profile")
    @MainActor
    func activeSessionReturnsFreshProfile() async {
        let profile = TelescanProfileResponse(
            telescanId: UUID(),
            name: "Fresh Ada",
            username: "fresh_ada",
            photoUrl: "https://cdn.example/fresh.jpg"
        )
        let validator = SessionValidator { profile }

        let result = await validator.validate()

        #expect(result == .active(profile))
    }

    @Test("Revoked and deleted sessions are invalid")
    @MainActor
    func revokedAndDeletedSessionsAreInvalid() async {
        let revoked = SessionValidator {
            throw APIClientError.unauthenticated
        }
        let deleted = SessionValidator {
            throw APIClientError.accountNotFound
        }

        #expect(await revoked.validate() == .invalid)
        #expect(await deleted.validate() == .invalid)
    }

    @Test("Temporary session validation failure keeps the local session")
    @MainActor
    func unavailableSessionValidationIsNonDestructive() async {
        let validator = SessionValidator {
            throw APIClientError.httpStatus(503)
        }

        #expect(await validator.validate() == .unavailable)
    }

    @Test("Installation device ID is stable and not hardware-derived")
    func stableInstallationID() throws {
        let store = MemorySecureStore()
        let identity = DeviceIdentity(store: store, key: "device")
        let first = try identity.value()
        let second = try identity.value()
        #expect(first == second)
    }

    @Test("401 refreshes, rotates Keychain tokens, and retries once")
    func refreshAndRetry() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        try sessions.save(
            TokenResponse(
                accessToken: "old-access-token",
                refreshToken: "old-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let profileID = UUID()
        var calls = 0
        MockURLProtocol.handler = { request in
            calls += 1
            if calls == 1 {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access-token")
                return (401, Data())
            }
            if request.url?.path == "/api/v1/auth/refresh" {
                return (
                    200,
                    Data(
                        """
                        {"accessToken":"new-access-token","refreshToken":"new-refresh-token-value-that-is-long-enough","tokenType":"bearer","expiresIn":900}
                        """.utf8
                    )
                )
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new-access-token")
            return (
                200,
                Data(
                    """
                    {"telescanId":"\(profileID.uuidString)","name":"Ada","username":"ada","photoUrl":null}
                    """.utf8
                )
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )
        let profile = try await client.currentProfile()
        #expect(profile.telescanId == profileID)
        #expect(sessions.accessToken == "new-access-token")
        #expect(calls == 3)
    }

    @Test("A final 401 invalidates the refreshed session")
    func finalUnauthorizedResponseClearsTokens() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        try sessions.save(
            TokenResponse(
                accessToken: "old-access-token",
                refreshToken: "old-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                return (
                    200,
                    Data(
                        """
                        {"accessToken":"new-access-token","refreshToken":"new-refresh-token-value-that-is-long-enough","tokenType":"bearer","expiresIn":900}
                        """.utf8
                    )
                )
            }
            return (401, Data())
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        do {
            let _: TelescanProfileResponse = try await client.currentProfile()
            Issue.record("Expected an unauthenticated error")
        } catch APIClientError.unauthenticated {
            #expect(!sessions.hasTokens)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A transient refresh failure preserves the local session")
    func transientRefreshFailureKeepsTokens() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        try sessions.save(
            TokenResponse(
                accessToken: "old-access-token",
                refreshToken: "old-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            request.url?.path == "/api/v1/auth/refresh"
                ? (503, Data())
                : (401, Data())
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        do {
            let _: TelescanProfileResponse = try await client.currentProfile()
            Issue.record("Expected a temporary HTTP error")
        } catch APIClientError.httpStatus(let status) {
            #expect(status == 503)
            #expect(sessions.hasTokens)
            #expect(sessions.accessToken == "old-access-token")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A missing refresh route is not mistaken for a deleted account")
    func refreshRouteNotFoundKeepsTokens() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        try sessions.save(
            TokenResponse(
                accessToken: "old-access-token",
                refreshToken: "old-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            request.url?.path == "/api/v1/auth/refresh"
                ? (404, Data())
                : (401, Data())
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        do {
            let _: TelescanProfileResponse = try await client.currentProfile()
            Issue.record("Expected a refresh route error")
        } catch APIClientError.httpStatus(let status) {
            #expect(status == 404)
            #expect(sessions.hasTokens)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A missing current profile is classified as a deleted account")
    func missingCurrentProfileIsDefinitive() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        try sessions.save(
            TokenResponse(
                accessToken: "access-token",
                refreshToken: "refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { _ in (404, Data()) }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        do {
            let _: TelescanProfileResponse = try await client.currentProfile()
            Issue.record("Expected a deleted-account error")
        } catch APIClientError.accountNotFound {
            #expect(sessions.hasTokens)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("A nearby row appears only after a complete matching profile loads")
    @MainActor
    func nearbyProfileIsResolvedBeforeDisplay() async throws {
        let manager = FakeBLEManager()
        let profileID = UUID()
        let viewModel = PeopleViewModel(bleManager: manager) { requestedID in
            try await Task.sleep(for: .milliseconds(100))
            return TelescanProfileResponse(
                telescanId: requestedID,
                name: nil,
                username: "nearby_user",
                photoUrl: nil
            )
        }

        manager.emitDiscovery(id: profileID.uuidString, rssi: -55)
        await Task.yield()
        #expect(viewModel.visibleUsers.isEmpty)

        try await Task.sleep(for: .milliseconds(150))
        #expect(viewModel.visibleUsers.count == 1)
        #expect(viewModel.visibleUsers.first?.id == profileID)
        #expect(viewModel.visibleUsers.first?.name == "@nearby_user")
        #expect(viewModel.visibleUsers.first?.username == "@nearby_user")
        viewModel.stopAllBluetoothActivity()
    }

    @Test("An incomplete nearby profile never produces an Unknown row")
    @MainActor
    func incompleteNearbyProfileStaysHidden() async throws {
        let manager = FakeBLEManager()
        let profileID = UUID()
        let viewModel = PeopleViewModel(bleManager: manager) { requestedID in
            TelescanProfileResponse(
                telescanId: requestedID,
                name: "No username",
                username: nil,
                photoUrl: nil
            )
        }

        manager.emitDiscovery(id: profileID.uuidString, rssi: -60)
        try await Task.sleep(for: .milliseconds(50))
        #expect(viewModel.visibleUsers.isEmpty)
        #expect(viewModel.userCache.isEmpty)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Losing a BLE candidate cancels profile publication")
    @MainActor
    func lostCandidateCannotAppearLater() async throws {
        let manager = FakeBLEManager()
        let profileID = UUID()
        let viewModel = PeopleViewModel(bleManager: manager) { requestedID in
            try await Task.sleep(for: .milliseconds(150))
            return TelescanProfileResponse(
                telescanId: requestedID,
                name: "Nearby",
                username: "nearby",
                photoUrl: nil
            )
        }

        manager.emitDiscovery(id: profileID.uuidString, rssi: -60)
        await Task.yield()
        manager.emitLoss(id: profileID.uuidString)
        try await Task.sleep(for: .milliseconds(200))

        #expect(viewModel.visibleUsers.isEmpty)
        #expect(viewModel.devices.isEmpty)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Concurrent 401 responses share one refresh rotation")
    func concurrentRequestsUseSingleRefresh() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        try sessions.save(
            TokenResponse(
                accessToken: "old-access-token",
                refreshToken: "old-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let profileID = UUID()
        let counters = RequestCounters()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                counters.recordRefresh()
                Thread.sleep(forTimeInterval: 0.05)
                return (
                    200,
                    Data(
                        """
                        {"accessToken":"new-access-token","refreshToken":"new-refresh-token-value-that-is-long-enough","tokenType":"bearer","expiresIn":900}
                        """.utf8
                    )
                )
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access-token" {
                counters.recordOldAccess()
                return (401, Data())
            }
            return (
                200,
                Data(
                    """
                    {"telescanId":"\(profileID.uuidString)","name":"Ada","username":"ada","photoUrl":null}
                    """.utf8
                )
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        async let first: TelescanProfileResponse = client.currentProfile()
        async let second: TelescanProfileResponse = client.currentProfile()
        let (firstProfile, secondProfile) = try await (first, second)
        let profiles = [firstProfile, secondProfile]

        #expect(profiles.allSatisfy { $0.telescanId == profileID })
        #expect(counters.refreshes == 1)
        #expect(counters.oldAccessRequests == 2)
    }
}

@MainActor
private func waitForCodeCheck(_ viewModel: CodeViewModel) async {
    for _ in 0..<100 where viewModel.isLoading {
        await Task.yield()
    }
}

private func clearStoredProfile() {
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: Keys.telescanIDKey.rawValue)
    defaults.removeObject(forKey: Keys.tgNameKey.rawValue)
    defaults.removeObject(forKey: Keys.usernameKey.rawValue)
    defaults.removeObject(forKey: Keys.photoS3URLKey.rawValue)
    defaults.removeObject(forKey: "cleanCode")
    defaults.removeObject(forKey: "userCode")
}

private final class MemorySecureStore: SecureStoring {
    private var values: [String: Data] = [:]

    func data(for key: String) throws -> Data? { values[key] }
    func set(_ data: Data, for key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
}

private final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))!

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (status, data) = Self.handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

private final class RequestCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var refreshCount = 0
    private var oldAccessCount = 0

    var refreshes: Int { lock.withLock { refreshCount } }
    var oldAccessRequests: Int { lock.withLock { oldAccessCount } }

    func recordRefresh() {
        lock.withLock { refreshCount += 1 }
    }

    func recordOldAccess() {
        lock.withLock { oldAccessCount += 1 }
    }
}

@MainActor
private final class FakeBLEManager: BLEManagerProtocol {
    weak var delegate: BLEManagerDelegate?
    var isBluetoothAvailable = true

    func startScanning() { }
    func restartScanning() { }
    func stopScanning() { }
    func startAdvertising(id: String) { }
    func restartAdvertising(id: String) { }
    func stopAdvertising() { }
    func reconcileDiscoveryState() { }
    func setApplicationActive(_ isActive: Bool) { }
    func reset() { }

    func emitDiscovery(id: String, rssi: Int) {
        delegate?.didDiscoverDevice(id: id, rssi: rssi)
    }

    func emitLoss(id: String) {
        delegate?.didLoseDevice(id: id)
    }
}
