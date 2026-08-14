import Foundation
import Testing
@testable import Telescan

@Suite("Authenticated API client", .serialized)
struct FetchServiceTests {
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
