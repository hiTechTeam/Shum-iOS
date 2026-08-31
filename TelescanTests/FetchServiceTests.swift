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
            return TelegramLinkResponse(
                access: AccessTokenResponse(
                    accessToken: "linked-access",
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

    @Test("BIO is saved independently from registration")
    @MainActor
    func bioIsSavedIndependentlyFromRegistration() async {
        clearStoredProfile()
        defer { clearStoredProfile() }
        let profileID = UUID()
        var submittedBio: String?
        let linkedProfile = TelescanProfileResponse(
            telescanId: profileID,
            name: "Ada",
            username: "ada",
            photoUrl: nil
        )
        let viewModel = CodeViewModel(
            linkAction: { _ in
                TelegramLinkResponse(
                    access: AccessTokenResponse(
                        accessToken: "linked-access",
                        tokenType: "bearer",
                        expiresIn: 900
                    ),
                    profile: linkedProfile
                )
            },
            updateBioAction: { bio in
                submittedBio = bio
                return TelescanProfileResponse(
                    telescanId: profileID,
                    name: "Ada",
                    username: "ada",
                    bio: bio,
                    photoUrl: nil
                )
            }
        )

        viewModel.tmpCode = "AB12CD34"
        viewModel.checkCode(viewModel.tmpCode)
        await waitForCodeCheck(viewModel)

        #expect(await viewModel.confirmCode())
        #expect(submittedBio == nil)
        #expect(await viewModel.updateBio("  iOS engineer. Open to meetups.  "))
        #expect(submittedBio == "iOS engineer. Open to meetups.")
        #expect(viewModel.bio == submittedBio)
        #expect(
            UserDefaults.standard.string(forKey: Keys.bioKey.rawValue)
                == submittedBio
        )

        let longBio = String(repeating: "a", count: 61)
        #expect(await viewModel.updateBio(longBio))
        #expect(submittedBio == String(repeating: "a", count: 36))
    }

    @Test("A validated code can be edited and checked again")
    @MainActor
    func validatedCodeCanBeReplaced() async {
        clearStoredProfile()
        defer { clearStoredProfile() }
        let profileID = UUID()
        let viewModel = CodeViewModel { code in
            TelegramLinkResponse(
                access: AccessTokenResponse(
                    accessToken: "linked-access",
                    tokenType: "bearer",
                    expiresIn: 900
                ),
                profile: TelescanProfileResponse(
                    telescanId: profileID,
                    name: "Ada",
                    username: code == "AB12CD34" ? "first" : "second",
                    photoUrl: nil
                )
            )
        }

        viewModel.tmpCode = "AB12CD34"
        viewModel.checkCode(viewModel.tmpCode)
        await waitForCodeCheck(viewModel)
        #expect(viewModel.codeStatus == true)
        #expect(viewModel.tmpTgUsername == "@first")

        viewModel.tmpCode = "AB12CD3"
        viewModel.checkCode(viewModel.tmpCode)
        #expect(viewModel.codeStatus == nil)
        #expect(viewModel.tmpTgUsername == nil)

        viewModel.tmpCode = "ZX98YU76"
        viewModel.checkCode(viewModel.tmpCode)
        await waitForCodeCheck(viewModel)
        #expect(viewModel.codeStatus == true)
        #expect(viewModel.tmpTgUsername == "@second")
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
        #expect(viewModel.codeError == .invalidCode)
        #expect(viewModel.tmpTgUsername == nil)
        #expect(await !viewModel.confirmCode())
    }

    @Test("A profile without a public Telegram username shows a specific error")
    @MainActor
    func missingTelegramUsernameShowsSpecificError() async {
        let viewModel = CodeViewModel { _ in
            throw APIClientError.telegramUsernameRequired
        }

        viewModel.tmpCode = "USERLESS"
        viewModel.checkCode(viewModel.tmpCode)
        await waitForCodeCheck(viewModel)

        #expect(viewModel.codeStatus == false)
        #expect(viewModel.codeError == .telegramUsernameRequired)
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

    @Test("A session without Telegram continues at the required link step")
    @MainActor
    func missingUsernameInvalidatesSession() async {
        let validator = SessionValidator {
            TelescanProfileResponse(
                telescanId: UUID(),
                name: "Ada",
                username: nil,
                photoUrl: nil
            )
        }

        let result = await validator.validate()
        guard case .telegramLinkRequired(let profile) = result else {
            Issue.record("Expected the Telegram linking state")
            return
        }
        #expect(profile.username == nil)
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

    @Test("Legacy tokens are not an Apple primary session")
    func legacyTokensRequireAppleSignIn() throws {
        let sessions = AuthSessionStore(store: MemorySecureStore())
        let tokens = TokenResponse(
            accessToken: "legacy-access",
            refreshToken: "legacy-refresh-token-value-that-is-long-enough",
            tokenType: "bearer",
            expiresIn: 900
        )

        try sessions.save(tokens)
        #expect(sessions.hasTokens)
        #expect(!sessions.hasPrimarySession)

        try sessions.saveAppleSession(tokens)
        #expect(sessions.hasPrimarySession)
    }

    @Test("Sign in with Apple creates and stores the primary session")
    func appleSignInCreatesPrimarySession() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let profileID = UUID()
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/auth/apple")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = requestBodyData(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            #expect(body?["identityToken"] as? String == "apple-identity-token")
            #expect(body?["nonce"] as? String == "raw-nonce-value")
            return (
                200,
                Data(
                    """
                    {
                      "tokens": {
                        "accessToken": "apple-access",
                        "refreshToken": "apple-refresh-token-value-that-is-long-enough",
                        "tokenType": "bearer",
                        "expiresIn": 900
                      },
                      "profile": {
                        "telescanId": "\(profileID.uuidString)",
                        "name": null,
                        "username": null,
                        "bio": null,
                        "photoUrl": null,
                        "telegramLinked": false
                      }
                    }
                    """.utf8
                )
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        let response = try await client.signInWithApple(
            identityToken: "apple-identity-token",
            nonce: "raw-nonce-value",
            name: "Ada"
        )

        #expect(!response.profile.isTelegramLinked)
        #expect(sessions.accessToken == "apple-access")
        #expect(sessions.hasPrimarySession)
        #expect(
            sessions.refreshToken
                == "apple-refresh-token-value-that-is-long-enough"
        )
    }

    @Test("Personal Team development linking creates a legacy session")
    func developmentTelegramLinkCreatesSession() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        try sessions.saveAppleSession(
            TokenResponse(
                accessToken: "old-apple-access",
                refreshToken: "old-apple-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let profileID = UUID()
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/auth/link")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let body = requestBodyData(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            #expect(body?["code"] as? String == "AB12CD34")
            #expect(body?["deviceId"] as? String != nil)
            return (
                200,
                Data(
                    """
                    {
                      "tokens": {
                        "accessToken": "development-access",
                        "refreshToken": "development-refresh-token-value-that-is-long-enough",
                        "tokenType": "bearer",
                        "expiresIn": 900
                      },
                      "profile": {
                        "telescanId": "\(profileID.uuidString)",
                        "name": "Ada",
                        "username": "ada",
                        "bio": null,
                        "photoUrl": null,
                        "telegramLinked": true
                      }
                    }
                    """.utf8
                )
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        let response = try await client.linkForDevelopment(code: "AB12CD34")

        #expect(response.profile.isTelegramLinked)
        #expect(sessions.hasTokens)
        #expect(!sessions.hasPrimarySession)
        #expect(sessions.accessToken == "development-access")
    }

    @Test("Telegram linking replaces access but preserves the Apple refresh token")
    func telegramLinkPreservesAppleRefreshToken() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        try sessions.saveAppleSession(
            TokenResponse(
                accessToken: "apple-access",
                refreshToken: "apple-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let profileID = UUID()
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/users/me/telegram/link")
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer apple-access"
            )
            return (
                200,
                Data(
                    """
                    {
                      "access": {
                        "accessToken": "linked-access",
                        "tokenType": "bearer",
                        "expiresIn": 900
                      },
                      "profile": {
                        "telescanId": "\(profileID.uuidString)",
                        "name": "Ada",
                        "username": "ada",
                        "bio": null,
                        "photoUrl": null,
                        "telegramLinked": true
                      }
                    }
                    """.utf8
                )
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        let response = try await client.linkTelegramForPersonalTeam(
            code: "AB12CD34"
        )

        #expect(response.profile.isTelegramLinked)
        #expect(sessions.hasPrimarySession)
        #expect(sessions.accessToken == "linked-access")
        #expect(
            sessions.refreshToken
                == "apple-refresh-token-value-that-is-long-enough"
        )
    }

    @Test("The API username-required response has a dedicated client error")
    func usernameRequiredResponseIsClassified() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        try sessions.save(
            TokenResponse(
                accessToken: "apple-access-token",
                refreshToken: "apple-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/users/me/telegram/link")
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer apple-access-token"
            )
            return (
                422,
                Data(
                    """
                    {"detail":"Public Telegram username is required","code":"telegram_username_required"}
                    """.utf8
                )
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        do {
            _ = try await client.linkTelegram(code: "USERLESS")
            Issue.record("Expected a Telegram username error")
        } catch APIClientError.telegramUsernameRequired {
            #expect(sessions.hasTokens)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Authenticated profile update sends and receives BIO")
    func profileBioUpdateUsesAuthenticatedPatch() async throws {
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
        let profileID = UUID()
        var requestCount = 0
        MockURLProtocol.handler = { request in
            requestCount += 1
            #expect(request.url?.path == "/api/v1/users/me")
            #expect(request.httpMethod == "PATCH")
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer access-token"
            )
            let body = requestBodyData(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            if requestCount == 1 {
                #expect(body?["bio"] as? String == "Open to networking")
            } else {
                #expect(body?["bio"] is NSNull)
            }
            let responseBio = requestCount == 1
                ? "\"Open to networking\""
                : "null"
            return (
                200,
                Data(
                    """
                    {"telescanId":"\(profileID.uuidString)","name":"Ada","username":"ada","bio":\(responseBio),"photoUrl":null}
                    """.utf8
                )
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        let profile = try await client.updateProfile(bio: "Open to networking")
        let cleared = try await client.updateProfile(bio: nil)

        #expect(profile.bio == "Open to networking")
        #expect(cleared.bio == nil)
        #expect(requestCount == 2)
    }

    @Test("Registration account actions issue authenticated deletes")
    func registrationAccountActionsUseAuthenticatedDeletes() async throws {
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
        var requests: [(method: String?, path: String?)] = []
        MockURLProtocol.handler = { request in
            requests.append((request.httpMethod, request.url?.path))
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer access-token"
            )
            return (204, Data())
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        try await client.logoutCurrentSession()
        try await client.deleteAccount()

        #expect(requests.count == 2)
        #expect(requests[0].method == "DELETE")
        #expect(requests[0].path == "/api/v1/auth/session")
        #expect(requests[1].method == "DELETE")
        #expect(requests[1].path == "/api/v1/users/me")
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

    @Test("Report and block requests use authenticated moderation endpoints")
    func moderationRequestsUseAuthenticatedAPI() async throws {
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
        let targetID = UUID()
        let reportID = UUID()
        let recorder = ModerationRequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            switch (request.httpMethod, request.url?.path) {
            case ("POST", "/api/v1/reports"):
                return (
                    201,
                    Data(
                        """
                        {"reportId":"\(reportID.uuidString)","status":"pending","createdAt":"2026-08-16T12:00:00Z"}
                        """.utf8
                    )
                )
            case (
                "PUT",
                "/api/v1/users/me/blocks/\(targetID.uuidString.lowercased())"
            ):
                return (
                    200,
                    Data(
                        """
                        {"telescanId":"\(targetID.uuidString)","name":"Target","username":"target","photoUrl":null,"blockedAt":"2026-08-16T12:00:00Z"}
                        """.utf8
                    )
                )
            case ("GET", "/api/v1/users/me/blocks"):
                return (
                    200,
                    Data(
                        """
                        [{"telescanId":"\(targetID.uuidString)","name":"Target","username":"target","photoUrl":null,"blockedAt":"2026-08-16T12:00:00Z"}]
                        """.utf8
                    )
                )
            default:
                return (404, Data())
            }
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        let report = try await client.submitReport(
            targetID: targetID,
            details: "context"
        )
        let blocked = try await client.blockProfile(id: targetID)
        let list = try await client.blockedProfiles()

        #expect(report.reportId == reportID)
        #expect(blocked.telescanId == targetID)
        #expect(list.map(\.telescanId) == [targetID])
        #expect(recorder.requests.count == 3)
        #expect(
            recorder.requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization")
                    == "Bearer access-token"
            }
        )
        let reportRequest = try #require(recorder.requests.first)
        let body = try #require(requestBodyData(reportRequest))
        let json = try #require(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        #expect(json["targetTelescanId"] as? String == targetID.uuidString)
        #expect(json["reason"] as? String == "other")
        #expect(json["details"] as? String == "context")
        #expect(json["clientRequestId"] as? String != nil)
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
                bio: "Open to conference meetups",
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
        #expect(viewModel.visibleUsers.first?.bio == "Open to conference meetups")
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Nearby profiles keep discovery stack order instead of distance order")
    @MainActor
    func nearbyProfilesUseStableDiscoveryOrder() async {
        let manager = FakeBLEManager()
        let firstID = UUID()
        let secondID = UUID()
        let viewModel = PeopleViewModel(bleManager: manager) { requestedID in
            TelescanProfileResponse(
                telescanId: requestedID,
                name: requestedID == firstID ? "First" : "Second",
                username: requestedID == firstID ? "first" : "second",
                photoUrl: nil
            )
        }

        manager.emitDiscovery(id: firstID.uuidString, rssi: -35)
        await Task.yield()
        await viewModel.loadUserIfNeeded(
            telescanID: firstID.uuidString.lowercased()
        )

        manager.emitDiscovery(id: secondID.uuidString, rssi: -90)
        await Task.yield()
        await viewModel.loadUserIfNeeded(
            telescanID: secondID.uuidString.lowercased()
        )

        #expect(viewModel.visibleUsers.map(\.id) == [secondID, firstID])

        manager.emitUpdate(id: firstID.uuidString, rssi: -100)
        manager.emitUpdate(id: secondID.uuidString, rssi: -30)
        await Task.yield()

        #expect(viewModel.visibleUsers.map(\.id) == [secondID, firstID])
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Encounter history persists, deduplicates and prunes old profiles")
    func encounterHistoryStoreMaintainsRecentUniqueProfiles() throws {
        let suiteName = "telescan.tests.encounters.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let start = Date(timeIntervalSince1970: 10_000)
        let first = NearbyUser(
            id: UUID(),
            name: "First",
            username: "@first",
            bio: "Original BIO",
            photoURL: "https://example.com/first.jpg"
        )
        let second = NearbyUser(
            id: UUID(),
            name: "Second",
            username: "@second",
            bio: nil,
            photoURL: nil
        )
        let updatedFirst = NearbyUser(
            id: first.id,
            name: "First Updated",
            username: "@first",
            bio: "Updated BIO",
            photoURL: first.photoURL
        )

        let store = EncounterHistoryStore(defaults: defaults)
        store.record(first, seenAt: start)
        store.record(second, seenAt: start.addingTimeInterval(50))
        store.record(updatedFirst, seenAt: start.addingTimeInterval(100))

        #expect(store.entries.map(\.id) == [first.id, second.id])
        #expect(store.entries.first?.user.name == "First Updated")
        #expect(store.entries.first?.user.bio == "Updated BIO")

        let restored = EncounterHistoryStore(defaults: defaults)
        #expect(restored.entries == store.entries)

        restored.prune(olderThan: start.addingTimeInterval(75))
        #expect(restored.entries.map(\.id) == [first.id])
    }

    @Test("Unviewed encounters persist until their rows are seen")
    func unviewedEncounterStorePersistsAndReconcilesIDs() throws {
        let suiteName = "telescan.tests.unviewed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstID = UUID()
        let secondID = UUID()
        let store = UnviewedEncounterStore(defaults: defaults)
        store.insert(firstID)
        store.insert(secondID)
        store.remove(firstID)

        let restored = UnviewedEncounterStore(defaults: defaults)
        #expect(restored.ids == [secondID])

        restored.retain([firstID])
        #expect(restored.ids.isEmpty)
    }

    @Test("Application badge combines Nearby and new Met profiles")
    @MainActor
    func applicationBadgeCombinesNearbyAndEncounterHistory() async {
        let manager = FakeBLEManager()
        let notifier = FakeNearbyPeopleNotifier()
        let historyStore = FakeEncounterHistoryStore()
        let unviewedStore = InMemoryUnviewedEncounterStore()
        let metUser = NearbyUser(
            id: UUID(),
            name: "Met",
            username: "@met",
            bio: nil,
            photoURL: nil
        )
        historyStore.record(metUser, seenAt: Date())
        unviewedStore.insert(metUser.id)
        let nearbyID = UUID()
        let viewModel = PeopleViewModel(
            bleManager: manager,
            nearbyPeopleNotifier: notifier,
            encounterHistoryStore: historyStore,
            unviewedEncounterStore: unviewedStore,
            profileLoader: { requestedID in
                TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Nearby",
                    username: "nearby",
                    photoUrl: nil
                )
            }
        )

        #expect(notifier.applicationIconBadgeCounts.last == 1)

        manager.emitDiscovery(id: nearbyID.uuidString, rssi: -55)
        await Task.yield()
        await viewModel.loadUserIfNeeded(
            telescanID: nearbyID.uuidString.lowercased()
        )

        #expect(viewModel.visibleUsers.count == 1)
        #expect(viewModel.encounterHistory.count == 1)
        #expect(notifier.applicationIconBadgeCounts.last == 2)

        viewModel.markEncounterViewed(metUser.id)
        #expect(notifier.applicationIconBadgeCounts.last == 1)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Encounter history records after the heartbeat buffer expires")
    @MainActor
    func encounterHeartbeatPublishesAfterInactivity() async {
        let manager = FakeBLEManager()
        let notifier = FakeNearbyPeopleNotifier()
        let historyStore = FakeEncounterHistoryStore()
        let bufferStore = FakeEncounterHistoryStore()
        let unviewedStore = InMemoryUnviewedEncounterStore()
        let profileID = UUID()
        let start = Date(timeIntervalSince1970: 20_000)
        var now = start
        let viewModel = PeopleViewModel(
            bleManager: manager,
            nearbyPeopleNotifier: notifier,
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            unviewedEncounterStore: unviewedStore,
            historyUpdateInterval: 60,
            encounterInactivityDelay: 0.5,
            profileLoader: { requestedID in
                TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Met user",
                    username: "met_user",
                    bio: "Conference attendee",
                    photoUrl: nil
                )
            },
            nowProvider: { now }
        )

        manager.emitDiscovery(id: profileID.uuidString, rssi: -55)
        await Task.yield()
        await viewModel.loadUserIfNeeded(
            telescanID: profileID.uuidString.lowercased()
        )

        #expect(viewModel.encounterHistory.isEmpty)
        #expect(historyStore.entries.isEmpty)
        #expect(historyStore.recordCount == 0)
        #expect(bufferStore.entries.first?.id == profileID)

        try? await Task.sleep(for: .milliseconds(350))
        now = start.addingTimeInterval(70)
        manager.emitUpdate(id: profileID.uuidString, rssi: -58)
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!viewModel.visibleUsers.isEmpty)
        #expect(historyStore.recordCount == 0)
        #expect(viewModel.encounterHistory.isEmpty)
        #expect(bufferStore.entries.first?.lastSeen == now)

        try? await Task.sleep(for: .milliseconds(300))
        #expect(viewModel.visibleUsers.isEmpty)
        #expect(viewModel.encounterHistory.first?.id == profileID)
        #expect(historyStore.entries.first?.lastSeen == now)
        #expect(historyStore.recordCount == 1)
        #expect(bufferStore.entries.isEmpty)
        #expect(viewModel.unviewedEncounterIDs == [profileID])
        #expect(viewModel.unviewedEncounterCount == 1)
        #expect(notifier.applicationIconBadgeCounts.last == 1)

        viewModel.markEncounterViewed(profileID)
        #expect(viewModel.unviewedEncounterCount == 0)
        #expect(notifier.applicationIconBadgeCounts.last == 0)

        now = start.addingTimeInterval(80)
        manager.emitDiscovery(id: profileID.uuidString, rssi: -56)
        await Task.yield()
        await viewModel.loadUserIfNeeded(
            telescanID: profileID.uuidString.lowercased()
        )
        #expect(!viewModel.visibleUsers.isEmpty)
        #expect(viewModel.encounterHistory.first?.id == profileID)

        try? await Task.sleep(for: .milliseconds(600))
        #expect(viewModel.visibleUsers.isEmpty)
        #expect(viewModel.encounterHistory.first?.id == profileID)
        #expect(historyStore.entries.first?.lastSeen == now)
        #expect(historyStore.recordCount == 2)
        #expect(bufferStore.entries.isEmpty)
        #expect(viewModel.unviewedEncounterIDs.isEmpty)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Pending BLE identities persist across process recreation")
    func pendingEncounterIdentityStorePersists() throws {
        let suiteName = "telescan.tests.pending-encounters.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let profileID = UUID()
        let seenAt = Date(timeIntervalSince1970: 25_000)

        let store = PendingEncounterIdentityStore(defaults: defaults)
        store.record(id: profileID, seenAt: seenAt)

        let restored = PendingEncounterIdentityStore(defaults: defaults)
        #expect(restored.entries.count == 1)
        #expect(restored.entries.first?.id == profileID)
        #expect(restored.entries.first?.lastSeen == seenAt)
    }

    @Test("Buffered encounters publish before the next scan starts")
    @MainActor
    func bufferedEncounterPublishesOnNextLaunch() {
        let historyStore = FakeEncounterHistoryStore()
        let bufferStore = FakeEncounterHistoryStore()
        let unviewedStore = InMemoryUnviewedEncounterStore()
        let user = NearbyUser(
            id: UUID(),
            name: "Interrupted encounter",
            username: "@interrupted",
            bio: nil,
            photoURL: nil
        )
        let lastSignal = Date(timeIntervalSince1970: 30_000)
        bufferStore.record(user, seenAt: lastSignal)

        let viewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            unviewedEncounterStore: unviewedStore,
            encounterRetention: nil,
            nowProvider: { lastSignal.addingTimeInterval(10) }
        )

        #expect(bufferStore.entries.isEmpty)
        #expect(historyStore.entries.first?.id == user.id)
        #expect(historyStore.entries.first?.lastSeen == lastSignal)
        #expect(viewModel.encounterHistory.first?.id == user.id)
        #expect(viewModel.unviewedEncounterIDs == [user.id])
        #expect(viewModel.visibleUsers.isEmpty)
        viewModel.markEncounterViewed(user.id)
        viewModel.stopAllBluetoothActivity()

        bufferStore.record(
            user,
            seenAt: lastSignal.addingTimeInterval(20)
        )
        let relaunchedViewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            unviewedEncounterStore: unviewedStore,
            encounterRetention: nil,
            nowProvider: { lastSignal.addingTimeInterval(30) }
        )

        #expect(relaunchedViewModel.unviewedEncounterIDs.isEmpty)
        relaunchedViewModel.stopAllBluetoothActivity()
    }

    @Test("An encounter becomes new again after leaving the 24-hour list")
    @MainActor
    func expiredEncounterBecomesUnviewedAgain() {
        let historyStore = FakeEncounterHistoryStore()
        let bufferStore = FakeEncounterHistoryStore()
        let unviewedStore = InMemoryUnviewedEncounterStore()
        let user = NearbyUser(
            id: UUID(),
            name: "Returned",
            username: "@returned",
            bio: nil,
            photoURL: nil
        )
        let oldDate = Date(timeIntervalSince1970: 50_000)
        let returnedAt = oldDate.addingTimeInterval(
            EncounterHistoryPolicy.retention + 1
        )
        historyStore.record(user, seenAt: oldDate)
        bufferStore.record(user, seenAt: returnedAt)

        let viewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            unviewedEncounterStore: unviewedStore,
            nowProvider: { returnedAt }
        )

        #expect(viewModel.unviewedEncounterIDs == [user.id])
        viewModel.stopAllBluetoothActivity()
    }

    @Test("A raw BLE identity survives a short background network window")
    @MainActor
    func pendingIdentityPublishesOnNextLaunch() async throws {
        let profileID = UUID()
        let firstManager = FakeBLEManager()
        let pendingStore = InMemoryPendingEncounterIdentityStore()
        let historyStore = FakeEncounterHistoryStore()
        let seenAt = Date(timeIntervalSince1970: 40_000)

        let firstViewModel = PeopleViewModel(
            bleManager: firstManager,
            encounterHistoryStore: historyStore,
            encounterBufferStore: FakeEncounterHistoryStore(),
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil,
            profileLoader: { requestedID in
                try await Task.sleep(for: .seconds(5))
                return TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Delayed",
                    username: "delayed",
                    photoUrl: nil
                )
            },
            nowProvider: { seenAt }
        )

        firstManager.emitDiscovery(id: profileID.uuidString, rssi: -60)
        await Task.yield()
        #expect(pendingStore.entries.first?.id == profileID)
        #expect(pendingStore.entries.first?.lastSeen == seenAt)
        firstViewModel.stopAllBluetoothActivity()

        let restoredViewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            encounterHistoryStore: historyStore,
            encounterBufferStore: FakeEncounterHistoryStore(),
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil,
            profileLoader: { requestedID in
                TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Recovered",
                    username: "recovered",
                    photoUrl: nil
                )
            },
            nowProvider: { seenAt.addingTimeInterval(10) }
        )

        try await Task.sleep(for: .milliseconds(50))
        #expect(pendingStore.entries.isEmpty)
        #expect(historyStore.entries.first?.id == profileID)
        #expect(historyStore.entries.first?.lastSeen == seenAt)
        #expect(restoredViewModel.encounterHistory.first?.id == profileID)
        restoredViewModel.stopAllBluetoothActivity()
    }

    @Test("Encounter history expires after 24 hours and clears locally")
    @MainActor
    func encounterHistoryExpiresAndClears() {
        let historyStore = FakeEncounterHistoryStore()
        let now = Date(timeIntervalSince1970: 200_000)
        let expired = NearbyUser(
            id: UUID(),
            name: "Expired",
            username: "@expired",
            bio: nil,
            photoURL: nil
        )
        let recent = NearbyUser(
            id: UUID(),
            name: "Recent",
            username: "@recent",
            bio: nil,
            photoURL: nil
        )
        historyStore.record(
            expired,
            seenAt: now.addingTimeInterval(-(24 * 60 * 60) - 1)
        )
        historyStore.record(
            recent,
            seenAt: now.addingTimeInterval(-60)
        )

        let viewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            encounterHistoryStore: historyStore,
            nowProvider: { now }
        )

        #expect(viewModel.encounterHistory.map(\.id) == [recent.id])
        viewModel.clearEncounterHistory()
        #expect(viewModel.encounterHistory.isEmpty)
        #expect(historyStore.entries.isEmpty)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("An incomplete nearby profile never produces an Unknown row")
    @MainActor
    func incompleteNearbyProfileStaysHidden() async throws {
        let manager = FakeBLEManager()
        let profileID = UUID()
        var attempts = 0
        let viewModel = PeopleViewModel(
            bleManager: manager,
            maximumProfileResolutionAttempts: 3,
            profileRetryBaseDelay: 0.01,
            maximumRetryDelay: 0.02
        ) { requestedID in
            attempts += 1
            return TelescanProfileResponse(
                telescanId: requestedID,
                name: "No username",
                username: nil,
                photoUrl: nil
            )
        }

        manager.emitDiscovery(id: profileID.uuidString, rssi: -60)
        try await Task.sleep(for: .milliseconds(150))
        #expect(viewModel.visibleUsers.isEmpty)
        #expect(viewModel.userCache.isEmpty)
        #expect(attempts == 1)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("A missing nearby profile is a terminal resolution failure")
    @MainActor
    func missingNearbyProfileDoesNotRetry() async throws {
        let manager = FakeBLEManager()
        let profileID = UUID()
        var attempts = 0
        let viewModel = PeopleViewModel(
            bleManager: manager,
            maximumProfileResolutionAttempts: 3,
            profileRetryBaseDelay: 0.01,
            maximumRetryDelay: 0.02
        ) { _ in
            attempts += 1
            throw APIClientError.httpStatus(404)
        }

        manager.emitDiscovery(id: profileID.uuidString, rssi: -60)
        try await Task.sleep(for: .milliseconds(150))

        #expect(viewModel.visibleUsers.isEmpty)
        #expect(attempts == 1)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Transient nearby profile failures stop at the retry budget")
    @MainActor
    func transientNearbyProfileRetriesAreBounded() async throws {
        let manager = FakeBLEManager()
        let profileID = UUID()
        var attempts = 0
        let viewModel = PeopleViewModel(
            bleManager: manager,
            maximumProfileResolutionAttempts: 3,
            profileRetryBaseDelay: 0.01,
            maximumRetryDelay: 0.02
        ) { _ in
            attempts += 1
            throw APIClientError.httpStatus(503)
        }

        manager.emitDiscovery(id: profileID.uuidString, rssi: -60)
        try await Task.sleep(for: .milliseconds(200))

        #expect(viewModel.visibleUsers.isEmpty)
        #expect(attempts == 3)
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

    @Test("Signal silence exposes and refresh clears the disappearance countdown")
    @MainActor
    func nearbyPresenceCountdownTracksSignals() async throws {
        let manager = FakeBLEManager()
        let profileID = UUID()
        let viewModel = PeopleViewModel(bleManager: manager) { requestedID in
            TelescanProfileResponse(
                telescanId: requestedID,
                name: "Nearby",
                username: "nearby",
                photoUrl: nil
            )
        }
        let discoveryID = profileID.uuidString.lowercased()

        manager.emitDiscovery(id: profileID.uuidString, rssi: -60)
        await Task.yield()
        #expect(viewModel.disappearanceCountdowns[discoveryID] == nil)

        viewModel.updateDisappearanceCountdowns(
            at: Date().addingTimeInterval(4)
        )
        let countdown = try #require(
            viewModel.disappearanceCountdowns[discoveryID]
        )
        #expect(countdown > 0)
        #expect(countdown < Int(BLEPresencePolicy.activeTimeout))

        manager.emitUpdate(id: profileID.uuidString, rssi: -58)
        await Task.yield()
        #expect(viewModel.disappearanceCountdowns[discoveryID] == nil)

        viewModel.updateDisappearanceCountdowns(
            at: Date().addingTimeInterval(4)
        )
        #expect(viewModel.disappearanceCountdowns[discoveryID] != nil)

        manager.emitLoss(id: profileID.uuidString)
        await Task.yield()
        #expect(viewModel.disappearanceCountdowns[discoveryID] == nil)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Nearby notifications aggregate people into numeric batches")
    func nearbyNotificationsAggregateNumericBatches() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var aggregator = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180
        )

        var firstBatch: NearbyNotificationBatch?
        for index in 0..<8 {
            let update = aggregator.detect(
                id: "person-\(index)",
                at: start.addingTimeInterval(Double(index))
            )
            if case .schedule(let batch) = update {
                firstBatch = batch
            }
        }

        let initial = try #require(firstBatch)
        #expect(initial.kind == .initial)
        #expect(initial.addedCount == 8)
        #expect(initial.totalCount == 8)
        #expect(initial.deliveryDate == start.addingTimeInterval(12))

        var secondBatch: NearbyNotificationBatch?
        for index in 8..<15 {
            let update = aggregator.detect(
                id: "person-\(index)",
                at: start.addingTimeInterval(13 + Double(index - 8))
            )
            if case .schedule(let batch) = update {
                secondBatch = batch
            }
        }

        let update = try #require(secondBatch)
        #expect(update.kind == .update)
        #expect(update.addedCount == 7)
        #expect(update.totalCount == 15)
        #expect(update.deliveryDate == start.addingTimeInterval(38))

        let duplicate = aggregator.detect(
            id: "person-14",
            at: start.addingTimeInterval(20)
        )
        #expect(duplicate == nil)
        #expect(aggregator.pendingIDs.count == 7)
        #expect(aggregator.nearbyIDs.count == 15)

        var thirdBatch: NearbyNotificationBatch?
        for index in 15..<17 {
            let update = aggregator.detect(
                id: "person-\(index)",
                at: start.addingTimeInterval(39 + Double(index - 15))
            )
            if case .schedule(let batch) = update {
                thirdBatch = batch
            }
        }

        let finalUpdate = try #require(thirdBatch)
        #expect(finalUpdate.kind == .update)
        #expect(finalUpdate.addedCount == 2)
        #expect(finalUpdate.totalCount == 17)
    }

    @Test("Nearby notification encounter resets after a quiet period")
    func nearbyNotificationEncounterResetsAfterQuietPeriod() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        var aggregator = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180
        )

        _ = aggregator.detect(id: "person", at: start)
        _ = aggregator.lose(id: "person", at: start.addingTimeInterval(20))

        #expect(
            aggregator.detect(
                id: "person",
                at: start.addingTimeInterval(100)
            ) == nil
        )
        _ = aggregator.lose(id: "person", at: start.addingTimeInterval(110))

        let restarted = aggregator.detect(
            id: "person",
            at: start.addingTimeInterval(300)
        )
        guard case .schedule(let batch) = restarted else {
            Issue.record("Expected a new encounter notification")
            return
        }
        #expect(batch.kind == .initial)
        #expect(batch.addedCount == 1)
        #expect(batch.totalCount == 1)
    }

    @Test("Nearby notification batch survives process recreation")
    func nearbyNotificationBatchSurvivesProcessRecreation() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        var original = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180
        )

        _ = original.detect(id: "first", at: start)
        var restored = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180,
            restoring: original.persistentState
        )

        #expect(
            restored.detect(
                id: "first",
                at: start.addingTimeInterval(2)
            ) == nil
        )

        let update = restored.detect(
            id: "second",
            at: start.addingTimeInterval(3)
        )
        guard case .schedule(let batch) = update else {
            Issue.record("Expected the restored pending batch")
            return
        }
        #expect(batch.kind == .initial)
        #expect(batch.addedCount == 2)
        #expect(batch.totalCount == 2)
        #expect(batch.deliveryDate == start.addingTimeInterval(12))
    }

    @Test("Nearby notification state persists in defaults")
    func nearbyNotificationStatePersistsInDefaults() throws {
        let suiteName = "NearbyNotificationStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var aggregator = NearbyEncounterAggregator()
        _ = aggregator.detect(id: "person", at: Date())
        let firstStore = NearbyNotificationStateStore(
            defaults: defaults,
            key: "state"
        )
        firstStore.save(aggregator.persistentState)

        let restoredStore = NearbyNotificationStateStore(
            defaults: defaults,
            key: "state"
        )
        #expect(restoredStore.state == aggregator.persistentState)
    }

    @Test("Background notification does not wait for profile loading")
    @MainActor
    func backgroundNotificationDoesNotWaitForProfileLoading() async {
        let manager = FakeBLEManager()
        let notifier = FakeNearbyPeopleNotifier()
        let profileID = UUID()
        let viewModel = PeopleViewModel(
            bleManager: manager,
            nearbyPeopleNotifier: notifier,
            profileLoader: { _ in
                try await Task.sleep(for: .seconds(30))
                throw CancellationError()
            }
        )

        viewModel.toggleScanning(true)
        viewModel.reconcileBluetoothState(
            isActive: false,
            scanningEnabled: true
        )
        manager.emitDiscovery(id: profileID.uuidString, rssi: -55)
        await Task.yield()

        #expect(notifier.scanningEnabled == true)
        #expect(
            notifier.detectedIDs == [
                profileID.uuidString.lowercased()
            ]
        )
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Entering background synchronizes recently seen people")
    @MainActor
    func enteringBackgroundSynchronizesRecentlySeenPeople() async {
        let manager = FakeBLEManager()
        let notifier = FakeNearbyPeopleNotifier()
        let profileID = UUID()
        let viewModel = PeopleViewModel(
            bleManager: manager,
            nearbyPeopleNotifier: notifier
        ) { requestedID in
            TelescanProfileResponse(
                telescanId: requestedID,
                name: "Nearby",
                username: "nearby",
                photoUrl: nil
            )
        }

        viewModel.toggleScanning(true)
        manager.emitDiscovery(id: profileID.uuidString, rssi: -55)
        await Task.yield()
        await viewModel.loadUserIfNeeded(
            telescanID: profileID.uuidString.lowercased()
        )
        viewModel.reconcileBluetoothState(isActive: false)

        #expect(notifier.synchronizedIDs == [profileID.uuidString.lowercased()])
        viewModel.stopAllBluetoothActivity()
    }

    @Test("A blocked nearby profile is hidden and excluded from notifications")
    @MainActor
    func blockedProfilesStayHidden() async throws {
        let manager = FakeBLEManager()
        let notifier = FakeNearbyPeopleNotifier()
        let blockedStore = FakeBlockedProfileStore()
        let profileID = UUID()
        blockedStore.insert(profileID)
        let viewModel = PeopleViewModel(
            bleManager: manager,
            nearbyPeopleNotifier: notifier,
            blockedProfileStore: blockedStore
        ) { requestedID in
            TelescanProfileResponse(
                telescanId: requestedID,
                name: "Blocked",
                username: "blocked",
                photoUrl: nil
            )
        }

        viewModel.toggleScanning(true)
        viewModel.reconcileBluetoothState(isActive: false)
        manager.emitDiscovery(id: profileID.uuidString, rssi: -55)
        await Task.yield()

        #expect(viewModel.visibleUsers.isEmpty)
        #expect(viewModel.devices.isEmpty)
        #expect(notifier.detectedIDs.isEmpty)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Successful blocking immediately removes a visible profile")
    @MainActor
    func blockingRemovesVisibleProfile() async throws {
        let manager = FakeBLEManager()
        let blockedStore = FakeBlockedProfileStore()
        let historyStore = FakeEncounterHistoryStore()
        let profileID = UUID()
        let viewModel = PeopleViewModel(
            bleManager: manager,
            blockedProfileStore: blockedStore,
            encounterHistoryStore: historyStore,
            profileLoader: { requestedID in
                TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Target",
                    username: "target",
                    photoUrl: nil
                )
            },
            blockSubmitter: { id in
                BlockedProfileResponse(
                    telescanId: id,
                    name: "Target",
                    username: "target",
                    photoUrl: nil,
                    blockedAt: "2026-08-16T12:00:00Z"
                )
            }
        )

        manager.emitDiscovery(id: profileID.uuidString, rssi: -55)
        await Task.yield()
        await viewModel.loadUserIfNeeded(
            telescanID: profileID.uuidString.lowercased()
        )
        let user = try #require(viewModel.visibleUsers.first)
        #expect(viewModel.encounterHistory.isEmpty)
        #expect(historyStore.entries.isEmpty)
        try await viewModel.block(user)

        #expect(viewModel.visibleUsers.isEmpty)
        #expect(viewModel.encounterHistory.isEmpty)
        #expect(historyStore.entries.isEmpty)
        #expect(blockedStore.ids == [profileID.uuidString.lowercased()])
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
    defaults.removeObject(forKey: Keys.bioKey.rawValue)
    defaults.removeObject(forKey: Keys.photoS3URLKey.rawValue)
    defaults.removeObject(forKey: "cleanCode")
    defaults.removeObject(forKey: "userCode")
}

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }

    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1_024)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        data.append(buffer, count: count)
    }
    return data
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

private final class ModerationRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.withLock { storedRequests }
    }

    func record(_ request: URLRequest) {
        lock.withLock { storedRequests.append(request) }
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

    func emitUpdate(id: String, rssi: Int) {
        delegate?.didUpdateDevice(id: id, rssi: rssi)
    }

    func emitLoss(id: String) {
        delegate?.didLoseDevice(id: id)
    }
}

@MainActor
private final class FakeNearbyPeopleNotifier: NearbyPeopleNotifying {
    private(set) var synchronizedIDs: Set<String> = []
    private(set) var detectedIDs: Set<String> = []
    private(set) var scanningEnabled = false
    private(set) var applicationIconBadgeCounts: [Int] = []

    func setScanningEnabled(_ enabled: Bool) {
        scanningEnabled = enabled
    }
    func setApplicationActive(_ isActive: Bool) { }
    func setApplicationIconBadgeCount(_ count: Int) {
        applicationIconBadgeCounts.append(count)
    }
    func synchronizeNearby(ids: Set<String>) {
        synchronizedIDs = ids
    }
    func detect(id: String) {
        detectedIDs.insert(id)
    }
    func lose(id: String) { }
    func reset() { }
}

private final class FakeBlockedProfileStore: BlockedProfileStoring {
    private(set) var ids: Set<String> = []

    func replace(with ids: Set<String>) {
        self.ids = ids
    }

    func insert(_ id: UUID) {
        ids.insert(id.uuidString.lowercased())
    }

    func remove(_ id: UUID) {
        ids.remove(id.uuidString.lowercased())
    }

    func removeAll() {
        ids.removeAll()
    }
}

private final class FakeEncounterHistoryStore: EncounterHistoryStoring {
    private(set) var entries: [EncounterHistoryEntry] = []
    private(set) var recordCount = 0

    func record(_ user: NearbyUser, seenAt: Date) {
        recordCount += 1
        let previousDate = entries.first { $0.id == user.id }?.lastSeen
        entries.removeAll { $0.id == user.id }
        entries.append(
            EncounterHistoryEntry(
                user: user,
                lastSeen: max(previousDate ?? seenAt, seenAt)
            )
        )
        entries.sort { $0.lastSeen > $1.lastSeen }
    }

    func remove(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
    }

    func prune(olderThan cutoff: Date) {
        entries.removeAll { $0.lastSeen < cutoff }
    }

    func removeAll() {
        entries.removeAll()
    }
}
