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
                LinkDeviceResponse(
                    tokens: TokenResponse(
                        accessToken: "access",
                        refreshToken: "refresh",
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

    @Test("A session without a public Telegram username is invalid")
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

        #expect(await validator.validate() == .invalid)
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

    @Test("The API username-required response has a dedicated client error")
    func usernameRequiredResponseIsClassified() async throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.handler = { request in
            #expect(request.url?.path == "/api/v1/auth/link")
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
            _ = try await client.link(code: "USERLESS")
            Issue.record("Expected a Telegram username error")
        } catch APIClientError.telegramUsernameRequired {
            #expect(!sessions.hasTokens)
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
            reason: .spam,
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
        #expect(json["reason"] as? String == "spam")
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
        let profileID = UUID()
        let viewModel = PeopleViewModel(
            bleManager: manager,
            blockedProfileStore: blockedStore,
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
        try await viewModel.block(user)

        #expect(viewModel.visibleUsers.isEmpty)
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

    func setScanningEnabled(_ enabled: Bool) { }
    func setApplicationActive(_ isActive: Bool) { }
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
