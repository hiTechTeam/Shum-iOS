import Foundation
import Testing
import UIKit
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

    @Test("A late account A BIO response cannot repopulate cleared profile state")
    @MainActor
    func lateBioResponseCannotCrossAccountReset() async {
        clearStoredProfile()
        defer { clearStoredProfile() }
        let accountAID = UUID()
        var continuation: CheckedContinuation<TelescanProfileResponse, Error>?
        let viewModel = CodeViewModel(
            linkAction: { _ in throw APIClientError.invalidResponse },
            updateBioAction: { _ in
                try await withCheckedThrowingContinuation {
                    continuation = $0
                }
            }
        )
        viewModel.applyProfile(
            TelescanProfileResponse(
                telescanId: accountAID,
                name: "Account A",
                username: "account_a",
                bio: "Old bio",
                photoUrl: nil
            )
        )

        let updateTask = Task { await viewModel.updateBio("Late bio") }
        while continuation == nil {
            await Task.yield()
        }

        AccountSessionGeneration.shared.advance()
        viewModel.clearProfile()
        clearStoredProfile()
        continuation?.resume(
            returning: TelescanProfileResponse(
                telescanId: accountAID,
                name: "Account A",
                username: "account_a",
                bio: "Late bio",
                photoUrl: nil
            )
        )
        continuation = nil

        #expect(await updateTask.value == false)
        #expect(viewModel.telescanID == nil)
        #expect(viewModel.bio == nil)
        #expect(
            UserDefaults.standard.string(forKey: Keys.bioKey.rawValue) == nil
        )
        #expect(
            UserDefaults.standard.string(
                forKey: Keys.telescanIDKey.rawValue
            ) == nil
        )
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

    @Test("A cold start without a primary session clears stale account data")
    @MainActor
    func coldStartWithoutPrimarySessionClearsStaleAccountData() throws {
        let defaults = UserDefaults.standard
        let accountMarkerKey = "telescan.tests.stale-account-marker"
        let historyStore = EncounterHistoryStore(defaults: defaults)
        let bufferStore = EncounterBufferStore(defaults: defaults)
        let unviewedStore = UnviewedEncounterStore(defaults: defaults)
        let pendingStore = PendingEncounterIdentityStore(defaults: defaults)
        let blockedStore = BlockedProfileStore(defaults: defaults)
        let peopleViewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            blockedProfileStore: blockedStore,
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            unviewedEncounterStore: unviewedStore,
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil
        )
        defer {
            peopleViewModel.stopAllBluetoothActivity()
            SavedPeopleStateStore.shared.removeAll()
            QuickActionsSettingsStore.shared.reset()
            ProfileImageStorage.delete()
            if let bundleID = Bundle.main.bundleIdentifier {
                defaults.removePersistentDomain(forName: bundleID)
            }
        }

        let sessions = AuthSessionStore(store: MemorySecureStore())
        let installationID = try sessions.installationDeviceID()
        let staleUser = NearbyUser(
            id: UUID(),
            name: "Stale account",
            username: "@stale_account",
            bio: "Must be cleared",
            photoURL: nil
        )
        let seenAt = Date(timeIntervalSince1970: 80_000)

        defaults.set(false, forKey: Keys.isReg.rawValue)
        defaults.set(true, forKey: Keys.isScaning.rawValue)
        defaults.set(
            staleUser.id.uuidString,
            forKey: Keys.telescanIDKey.rawValue
        )
        defaults.set(staleUser.name, forKey: Keys.tgNameKey.rawValue)
        defaults.set(staleUser.username, forKey: Keys.usernameKey.rawValue)
        defaults.set(staleUser.bio, forKey: Keys.bioKey.rawValue)
        defaults.set("stale", forKey: accountMarkerKey)
        historyStore.record(staleUser, seenAt: seenAt)
        bufferStore.record(staleUser, seenAt: seenAt)
        unviewedStore.insert(staleUser.id)
        pendingStore.record(id: staleUser.id, seenAt: seenAt)
        blockedStore.insert(staleUser.id)
        _ = SavedPeopleStateStore.shared.toggle(staleUser)
        QuickActionsSettingsStore.shared.isQuickChatEnabled = true
        QuickActionsSettingsStore.shared.isQuickBlockEnabled = true
        QuickActionsSettingsStore.shared.isQuickClearEnabled = true

        let staleImage = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2)
        ).image { context in
            UIColor.red.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        ProfileImageStorage.save(staleImage)
        let photoViewModel = ProfilePhotoViewModel()
        #expect(photoViewModel.uiImage != nil)

        let codeViewModel = CodeViewModel()
        let coordinator = AppCoordinator(
            authSession: sessions,
            authCodeViewModel: codeViewModel,
            peopleViewModel: peopleViewModel,
            profilePhotoViewModel: photoViewModel,
            bluetoothReset: { }
        )

        #expect(!coordinator.isAuthenticated)
        #expect(!coordinator.isRegistered)
        #expect(!coordinator.isScaning)
        #expect(codeViewModel.telescanID == nil)
        #expect(codeViewModel.tgName == nil)
        #expect(codeViewModel.tgUsername == nil)
        #expect(codeViewModel.bio == nil)
        #expect(photoViewModel.uiImage == nil)
        #expect(ProfileImageStorage.load() == nil)
        #expect(historyStore.entries.isEmpty)
        #expect(bufferStore.entries.isEmpty)
        #expect(unviewedStore.ids.isEmpty)
        #expect(pendingStore.entries.isEmpty)
        #expect(blockedStore.ids.isEmpty)
        #expect(peopleViewModel.visibleUsers.isEmpty)
        #expect(SavedPeopleStateStore.shared.count == 0)
        #expect(!QuickActionsSettingsStore.shared.hasEnabledActions)
        #expect(defaults.object(forKey: accountMarkerKey) == nil)
        #expect(!sessions.hasTokens)
        #expect(try sessions.installationDeviceID() == installationID)

        let restartedHistory = EncounterHistoryStore(defaults: defaults)
        let restartedBuffer = EncounterBufferStore(defaults: defaults)
        let restartedUnviewed = UnviewedEncounterStore(defaults: defaults)
        let restartedPending = PendingEncounterIdentityStore(defaults: defaults)
        let restartedBlocked = BlockedProfileStore(defaults: defaults)
        #expect(restartedHistory.entries.isEmpty)
        #expect(restartedBuffer.entries.isEmpty)
        #expect(restartedUnviewed.ids.isEmpty)
        #expect(restartedPending.entries.isEmpty)
        #expect(restartedBlocked.ids.isEmpty)
    }

    @Test("Logout resets local account state when the network is unavailable")
    @MainActor
    func logoutNetworkFailureStillResetsLocally() async throws {
        let sessions = AuthSessionStore(store: MemorySecureStore())
        try sessions.saveAppleSession(testTokens(account: "account-a"))
        UserDefaults.standard.set(true, forKey: Keys.isReg.rawValue)
        let people = PeopleViewModel(bleManager: FakeBLEManager())
        let peopleGeneration = people.accountStateGeneration
        var bluetoothResetCount = 0
        let coordinator = AppCoordinator(
            authSession: sessions,
            peopleViewModel: people,
            logoutAction: { _ in throw URLError(.notConnectedToInternet) },
            bluetoothReset: { bluetoothResetCount += 1 }
        )

        try await coordinator.logoutCurrentSession()

        #expect(!sessions.hasTokens)
        #expect(!coordinator.isAuthenticated)
        #expect(!coordinator.isRegistered)
        #expect(people.accountStateGeneration != peopleGeneration)
        #expect(bluetoothResetCount == 1)
        people.stopAllBluetoothActivity()
    }

    @Test("Logout resets locally when the server response is lost")
    @MainActor
    func logoutLostResponseStillResetsLocally() async throws {
        let sessions = AuthSessionStore(store: MemorySecureStore())
        try sessions.saveAppleSession(testTokens(account: "account-a"))
        UserDefaults.standard.set(true, forKey: Keys.isReg.rawValue)
        var requestReachedServer = false
        let people = PeopleViewModel(bleManager: FakeBLEManager())
        let coordinator = AppCoordinator(
            authSession: sessions,
            peopleViewModel: people,
            logoutAction: { _ in
                requestReachedServer = true
                throw URLError(.networkConnectionLost)
            },
            bluetoothReset: { }
        )

        try await coordinator.logoutCurrentSession()

        #expect(requestReachedServer)
        #expect(!sessions.hasTokens)
        #expect(!coordinator.isAuthenticated)
        people.stopAllBluetoothActivity()
    }

    @Test("A late account A logout cannot reset account B")
    @MainActor
    func lateLogoutCannotResetNewLogin() async throws {
        let sessions = AuthSessionStore(store: MemorySecureStore())
        try sessions.saveAppleSession(testTokens(account: "account-a"))
        UserDefaults.standard.set(true, forKey: Keys.isReg.rawValue)
        var continuation: CheckedContinuation<Void, Error>?
        var bluetoothResetCount = 0
        let people = PeopleViewModel(bleManager: FakeBLEManager())
        let peopleGeneration = people.accountStateGeneration
        let coordinator = AppCoordinator(
            authSession: sessions,
            peopleViewModel: people,
            logoutAction: { token in
                #expect(token == "account-a-access")
                try await withCheckedThrowingContinuation {
                    continuation = $0
                }
            },
            bluetoothReset: { bluetoothResetCount += 1 }
        )
        let logout = Task { try await coordinator.logoutCurrentSession() }
        while continuation == nil { await Task.yield() }

        #expect(!sessions.hasTokens)
        #expect(!coordinator.isAuthenticated)
        #expect(bluetoothResetCount == 1)

        let accountBTokens = testTokens(account: "account-b")
        try sessions.saveAppleSession(accountBTokens)
        let accountBID = UUID()
        coordinator.completedAppleSignIn(
            profile: TelescanProfileResponse(
                telescanId: accountBID,
                name: "Account B",
                username: "account_b",
                photoUrl: nil
            )
        )
        let accountBPeopleGeneration = people.accountStateGeneration
        continuation?.resume(throwing: URLError(.networkConnectionLost))
        continuation = nil
        try await logout.value

        #expect(sessions.accessToken == accountBTokens.accessToken)
        #expect(sessions.refreshToken == accountBTokens.refreshToken)
        #expect(coordinator.isAuthenticated)
        #expect(coordinator.isRegistered)
        #expect(people.accountStateGeneration != peopleGeneration)
        #expect(people.accountStateGeneration == accountBPeopleGeneration)
        #expect(bluetoothResetCount == 1)
        people.stopAllBluetoothActivity()
    }

    @Test("A stale account generation cannot overwrite or clear a new session")
    func staleAccountGenerationCannotMutateNewSession() throws {
        let store = MemorySecureStore()
        let sessions = AuthSessionStore(store: store)
        let deviceID = try sessions.installationDeviceID()
        let accountA = TokenResponse(
            accessToken: "account-a-access",
            refreshToken: "account-a-refresh-token-value-that-is-long-enough",
            tokenType: "bearer",
            expiresIn: 900
        )
        let accountB = TokenResponse(
            accessToken: "account-b-access",
            refreshToken: "account-b-refresh-token-value-that-is-long-enough",
            tokenType: "bearer",
            expiresIn: 900
        )
        let delayedAccountARefresh = TokenResponse(
            accessToken: "late-account-a-access",
            refreshToken: "late-account-a-refresh-token-value-that-is-long-enough",
            tokenType: "bearer",
            expiresIn: 900
        )

        try sessions.saveAppleSession(accountA)
        let accountAGeneration = sessions.credentialGeneration
        sessions.clearTokens()
        try sessions.saveAppleSession(accountB)

        #expect(
            try !sessions.save(
                delayedAccountARefresh,
                ifGenerationMatches: accountAGeneration
            )
        )
        #expect(!sessions.clearTokens(ifGenerationMatches: accountAGeneration))
        #expect(sessions.accessToken == accountB.accessToken)
        #expect(sessions.refreshToken == accountB.refreshToken)
        #expect(sessions.hasPrimarySession)

        let restored = AuthSessionStore(store: store)
        #expect(try restored.installationDeviceID() == deviceID)
        #expect(restored.accessToken == accountB.accessToken)
        #expect(restored.refreshToken == accountB.refreshToken)
    }

    @Test("A failed credential removal leaves a durable fail-closed reset")
    func failedCredentialRemovalRemainsFailClosedAfterRestart() throws {
        let suiteName = "telescan.tests.auth-reset.\(UUID().uuidString)"
        let resetDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { resetDefaults.removePersistentDomain(forName: suiteName) }
        let store = FaultInjectingSecureStore()
        let sessions = AuthSessionStore(
            store: store,
            resetDefaults: resetDefaults
        )
        let oldTokens = TokenResponse(
            accessToken: "old-account-access",
            refreshToken: "old-account-refresh-token-value-that-is-long-enough",
            tokenType: "bearer",
            expiresIn: 900
        )
        let newTokens = TokenResponse(
            accessToken: "new-account-access",
            refreshToken: "new-account-refresh-token-value-that-is-long-enough",
            tokenType: "bearer",
            expiresIn: 900
        )

        try sessions.saveAppleSession(oldTokens)
        store.failRemovals = true
        #expect(!sessions.clearTokens())
        #expect(sessions.hasPendingReset)
        #expect(sessions.accessToken == nil)
        #expect(sessions.refreshToken == nil)
        #expect(!sessions.hasPrimarySession)

        let restarted = AuthSessionStore(
            store: store,
            resetDefaults: resetDefaults
        )
        #expect(restarted.hasPendingReset)
        #expect(restarted.accessToken == nil)
        #expect(!restarted.hasPrimarySession)

        store.failRemovals = false
        try restarted.saveAppleSession(newTokens)
        #expect(!restarted.hasPendingReset)
        #expect(restarted.accessToken == newTokens.accessToken)
        #expect(restarted.refreshToken == newTokens.refreshToken)
        #expect(restarted.hasPrimarySession)
    }

    @Test("A failed credential verification also survives restart fail closed")
    func failedCredentialVerificationRemainsFailClosedAfterRestart() throws {
        let suiteName = "telescan.tests.auth-reset.\(UUID().uuidString)"
        let resetDefaults = try #require(UserDefaults(suiteName: suiteName))
        defer { resetDefaults.removePersistentDomain(forName: suiteName) }
        let store = FaultInjectingSecureStore()
        let sessions = AuthSessionStore(
            store: store,
            resetDefaults: resetDefaults
        )
        try sessions.saveAppleSession(
            TokenResponse(
                accessToken: "account-access",
                refreshToken: "account-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )

        store.failReads = true
        #expect(!sessions.clearTokens())
        #expect(sessions.hasPendingReset)
        #expect(sessions.credentials.accessToken == nil)
        #expect(!sessions.hasPrimarySession)

        let restarted = AuthSessionStore(
            store: store,
            resetDefaults: resetDefaults
        )
        #expect(restarted.hasPendingReset)
        #expect(restarted.credentials.refreshToken == nil)
        #expect(!restarted.hasPrimarySession)

        store.failReads = false
        #expect(restarted.clearTokens())
        #expect(!restarted.hasPendingReset)
        #expect(!restarted.hasTokens)
        #expect(!restarted.hasPrimarySession)
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

    @Test("A delayed account A refresh cannot overwrite account B tokens")
    func delayedRefreshCannotOverwriteNewAccount() async throws {
        let sessions = AuthSessionStore(store: MemorySecureStore())
        try sessions.saveAppleSession(
            TokenResponse(
                accessToken: "account-a-access",
                refreshToken: "account-a-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let refreshGate = BlockingRequestGate()
        MockURLProtocol.handler = { request in
            if request.url?.path == "/api/v1/auth/refresh" {
                refreshGate.markStartedAndWait()
                return (
                    200,
                    Data(
                        """
                        {"accessToken":"late-account-a-access","refreshToken":"late-account-a-refresh-token-value-that-is-long-enough","tokenType":"bearer","expiresIn":900}
                        """.utf8
                    )
                )
            }
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer account-a-access"
            )
            return (401, Data())
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        let requestTask = Task {
            do {
                let _: TelescanProfileResponse = try await client.currentProfile()
                return false
            } catch {
                return true
            }
        }
        for _ in 0..<200 where !refreshGate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(refreshGate.hasStarted)
        sessions.clearTokens()
        let accountB = TokenResponse(
            accessToken: "account-b-access",
            refreshToken: "account-b-refresh-token-value-that-is-long-enough",
            tokenType: "bearer",
            expiresIn: 900
        )
        try sessions.saveAppleSession(accountB)
        refreshGate.open()

        #expect(await requestTask.value)
        #expect(sessions.accessToken == accountB.accessToken)
        #expect(sessions.refreshToken == accountB.refreshToken)
        #expect(sessions.hasPrimarySession)
    }

    @Test("A delayed successful account A response cannot escape into account B")
    func delayedAuthenticatedResponseCannotCrossAccountReset() async throws {
        let sessions = AuthSessionStore(store: MemorySecureStore())
        try sessions.saveAppleSession(
            TokenResponse(
                accessToken: "account-a-access",
                refreshToken: "account-a-refresh-token-value-that-is-long-enough",
                tokenType: "bearer",
                expiresIn: 900
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let responseGate = BlockingRequestGate()
        let accountAProfileID = UUID()
        MockURLProtocol.handler = { request in
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer account-a-access"
            )
            responseGate.markStartedAndWait()
            return (
                200,
                Data(
                    """
                    {"telescanId":"\(accountAProfileID.uuidString)","name":"Account A","username":"account_a","photoUrl":null}
                    """.utf8
                )
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )

        let requestTask = Task {
            do {
                let _: TelescanProfileResponse = try await client.currentProfile()
                return false
            } catch {
                return true
            }
        }
        for _ in 0..<200 where !responseGate.hasStarted {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(responseGate.hasStarted)
        sessions.clearTokens()
        let accountB = TokenResponse(
            accessToken: "account-b-access",
            refreshToken: "account-b-refresh-token-value-that-is-long-enough",
            tokenType: "bearer",
            expiresIn: 900
        )
        try sessions.saveAppleSession(accountB)
        responseGate.open()

        #expect(await requestTask.value)
        #expect(sessions.accessToken == accountB.accessToken)
        #expect(sessions.refreshToken == accountB.refreshToken)
        #expect(sessions.hasPrimarySession)
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
        let clientRequestID = UUID()
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
            details: "context",
            requestID: clientRequestID
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
        #expect(
            json["clientRequestId"] as? String
                == clientRequestID.uuidString
        )
    }

    @Test("Report comment is optional and limited to 500 characters")
    func reportCommentContractIsEnforcedClientSide() async throws {
        let sessions = AuthSessionStore(store: MemorySecureStore())
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
            return (
                201,
                Data(
                    """
                    {"reportId":"\(reportID.uuidString)","status":"pending","createdAt":"2026-09-01T12:00:00Z"}
                    """.utf8
                )
            )
        }
        let client = APIClient(
            baseURL: URL(string: "https://api.example")!,
            session: session,
            sessionStore: sessions
        )
        let maximumComment = String(
            repeating: "x",
            count: ReportCommentPolicy.maximumLength
        )

        _ = try await client.submitReport(
            targetID: targetID,
            details: "   \n",
            requestID: UUID()
        )
        _ = try await client.submitReport(
            targetID: targetID,
            details: maximumComment,
            requestID: UUID()
        )

        do {
            _ = try await client.submitReport(
                targetID: targetID,
                details: maximumComment + "x",
                requestID: UUID()
            )
            Issue.record("Expected an overlong report comment error")
        } catch let error as ReportCommentValidationError {
            #expect(
                error == .tooLong(
                    maximum: ReportCommentPolicy.maximumLength
                )
            )
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(recorder.requests.count == 2)
        let emptyBody = try #require(
            requestBodyData(recorder.requests[0])
        )
        let emptyJSON = try #require(
            JSONSerialization.jsonObject(with: emptyBody) as? [String: Any]
        )
        #expect(emptyJSON["details"] == nil)

        let maximumBody = try #require(
            requestBodyData(recorder.requests[1])
        )
        let maximumJSON = try #require(
            JSONSerialization.jsonObject(with: maximumBody) as? [String: Any]
        )
        #expect(maximumJSON["details"] as? String == maximumComment)
    }

    @Test("Report retries reuse one client request ID")
    func reportRetriesReuseClientRequestID() async throws {
        let sessions = AuthSessionStore(store: MemorySecureStore())
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
        let clientRequestID = UUID()
        let recorder = ModerationRequestRecorder()
        MockURLProtocol.handler = { request in
            recorder.record(request)
            if recorder.requests.count == 1 {
                return (503, Data())
            }
            return (
                201,
                Data(
                    """
                    {"reportId":"\(reportID.uuidString)","status":"pending","createdAt":"2026-09-01T12:00:00Z"}
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
            _ = try await client.submitReport(
                targetID: targetID,
                details: "same operation",
                requestID: clientRequestID
            )
            Issue.record("Expected the first report attempt to fail")
        } catch APIClientError.httpStatus(let status) {
            #expect(status == 503)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        let response = try await client.submitReport(
            targetID: targetID,
            details: "same operation",
            requestID: clientRequestID
        )

        #expect(response.reportId == reportID)
        #expect(recorder.requests.count == 2)
        let requestIDs = try recorder.requests.map { request in
            let body = try #require(requestBodyData(request))
            let json = try #require(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )
            return try #require(json["clientRequestId"] as? String)
        }
        #expect(requestIDs == [
            clientRequestID.uuidString,
            clientRequestID.uuidString
        ])
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

    @Test("Encounter buffer does not discard resolved profiles at 500 entries")
    func encounterBufferHasNoProfileLimit() throws {
        let suiteName = "telescan.tests.encounter-buffer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = EncounterBufferStore(defaults: defaults)
        for index in 0..<501 {
            store.record(
                NearbyUser(
                    id: UUID(),
                    name: "Profile \(index)",
                    username: "@profile\(index)",
                    bio: nil,
                    photoURL: nil
                ),
                seenAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        #expect(store.entries.count == 501)
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

    @Test("Quick actions reset their in-memory and persisted state")
    func quickActionsResetOnSessionCleanup() throws {
        let suiteName = "telescan.tests.quick-actions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = QuickActionsSettingsStore(defaults: defaults)
        store.isQuickChatEnabled = true
        store.isQuickClearEnabled = true
        store.isQuickBlockEnabled = true

        store.reset()

        #expect(!store.isQuickChatEnabled)
        #expect(!store.isQuickClearEnabled)
        #expect(!store.isQuickBlockEnabled)
        #expect(!QuickActionsSettingsStore(defaults: defaults).hasEnabledActions)
    }

    @Test("Saved profiles clear their in-memory state during session cleanup")
    func savedProfilesClearOnSessionCleanup() {
        let store = SavedPeopleStateStore.shared
        let user = NearbyUser(
            id: UUID(),
            name: "Saved",
            username: "@saved",
            bio: nil,
            photoURL: nil
        )
        store.removeAll()
        defer { store.removeAll() }

        _ = store.toggle(user)
        #expect(store.contains(user.id))

        store.removeAll()

        #expect(!store.contains(user.id))
        #expect(store.users.isEmpty)
        #expect(store.count == 0)
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

    @Test("Account reset removes every persisted encounter surface before account B")
    @MainActor
    func accountResetClearsEncounterStateAcrossRestart() throws {
        let suiteName = "telescan.tests.account-reset.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let historyStore = EncounterHistoryStore(defaults: defaults)
        let bufferStore = EncounterBufferStore(defaults: defaults)
        let unviewedStore = UnviewedEncounterStore(defaults: defaults)
        let pendingStore = PendingEncounterIdentityStore(defaults: defaults)
        let blockedStore = BlockedProfileStore(defaults: defaults)
        let notifier = FakeNearbyPeopleNotifier()
        let accountAUser = NearbyUser(
            id: UUID(),
            name: "Account A encounter",
            username: "@account_a",
            bio: nil,
            photoURL: nil
        )
        let seenAt = Date(timeIntervalSince1970: 60_000)
        let viewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            nearbyPeopleNotifier: notifier,
            blockedProfileStore: blockedStore,
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            unviewedEncounterStore: unviewedStore,
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil
        )

        historyStore.record(accountAUser, seenAt: seenAt)
        bufferStore.record(accountAUser, seenAt: seenAt)
        unviewedStore.insert(accountAUser.id)
        pendingStore.record(id: accountAUser.id, seenAt: seenAt)
        blockedStore.insert(accountAUser.id)

        viewModel.resetAccountScopedState()

        #expect(historyStore.entries.isEmpty)
        #expect(bufferStore.entries.isEmpty)
        #expect(unviewedStore.ids.isEmpty)
        #expect(pendingStore.entries.isEmpty)
        #expect(blockedStore.ids.isEmpty)
        #expect(viewModel.visibleUsers.isEmpty)
        #expect(viewModel.encounterHistory.isEmpty)
        #expect(viewModel.unviewedEncounterIDs.isEmpty)
        #expect(notifier.resetCount == 1)

        let restartedHistory = EncounterHistoryStore(defaults: defaults)
        let restartedBuffer = EncounterBufferStore(defaults: defaults)
        let restartedUnviewed = UnviewedEncounterStore(defaults: defaults)
        let restartedPending = PendingEncounterIdentityStore(defaults: defaults)
        let restartedBlocked = BlockedProfileStore(defaults: defaults)
        #expect(restartedHistory.entries.isEmpty)
        #expect(restartedBuffer.entries.isEmpty)
        #expect(restartedUnviewed.ids.isEmpty)
        #expect(restartedPending.entries.isEmpty)
        #expect(restartedBlocked.ids.isEmpty)

        let accountBUser = NearbyUser(
            id: UUID(),
            name: "Account B encounter",
            username: "@account_b",
            bio: nil,
            photoURL: nil
        )
        restartedHistory.record(accountBUser, seenAt: seenAt)
        let accountBRestart = EncounterHistoryStore(defaults: defaults)
        #expect(accountBRestart.entries.map(\.id) == [accountBUser.id])
        #expect(!accountBRestart.entries.contains { $0.id == accountAUser.id })
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Block purges persisted encounter state across restart and unblock")
    @MainActor
    func blockRestartUnblockDoesNotRestoreMet() async throws {
        let suiteName = "telescan.tests.block-purge.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let savedPeople = SavedPeopleStateStore.shared
        savedPeople.removeAll()
        defer { savedPeople.removeAll() }

        let target = NearbyUser(
            id: UUID(),
            name: "Blocked target",
            username: "@blocked_target",
            bio: nil,
            photoURL: nil
        )
        let seenAt = Date(timeIntervalSince1970: 70_000)
        let historyStore = EncounterHistoryStore(defaults: defaults)
        let bufferStore = EncounterBufferStore(defaults: defaults)
        let unviewedStore = UnviewedEncounterStore(defaults: defaults)
        let pendingStore = PendingEncounterIdentityStore(defaults: defaults)
        let blockedStore = BlockedProfileStore(defaults: defaults)
        let blockedResponse = BlockedProfileResponse(
            telescanId: target.id,
            name: target.name,
            username: target.username,
            photoUrl: target.photoURL,
            blockedAt: "2026-09-01T12:00:00Z"
        )
        let viewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            blockedProfileStore: blockedStore,
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            unviewedEncounterStore: unviewedStore,
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil,
            blockSubmitter: { _ in blockedResponse }
        )
        historyStore.record(target, seenAt: seenAt)
        bufferStore.record(target, seenAt: seenAt)
        unviewedStore.insert(target.id)
        pendingStore.record(id: target.id, seenAt: seenAt)
        _ = savedPeople.toggle(target)

        try await viewModel.block(target)

        #expect(historyStore.entries.isEmpty)
        #expect(bufferStore.entries.isEmpty)
        #expect(unviewedStore.ids.isEmpty)
        #expect(pendingStore.entries.isEmpty)
        #expect(blockedStore.ids == [target.discoveryID])
        #expect(savedPeople.contains(target.id))
        #expect(viewModel.isProfileBlocked(target.id))
        viewModel.stopAllBluetoothActivity()

        let restartedHistory = EncounterHistoryStore(defaults: defaults)
        let restartedBuffer = EncounterBufferStore(defaults: defaults)
        let restartedUnviewed = UnviewedEncounterStore(defaults: defaults)
        let restartedPending = PendingEncounterIdentityStore(defaults: defaults)
        let restartedBlocked = BlockedProfileStore(defaults: defaults)
        let relaunchedViewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            blockedProfileStore: restartedBlocked,
            encounterHistoryStore: restartedHistory,
            encounterBufferStore: restartedBuffer,
            unviewedEncounterStore: restartedUnviewed,
            pendingEncounterIdentityStore: restartedPending,
            encounterRetention: nil,
            unblockSubmitter: { id in #expect(id == target.id) }
        )

        #expect(relaunchedViewModel.isProfileBlocked(target.id))
        #expect(relaunchedViewModel.encounterHistory.isEmpty)
        try await relaunchedViewModel.unblock(blockedResponse)
        #expect(!relaunchedViewModel.isProfileBlocked(target.id))
        #expect(relaunchedViewModel.encounterHistory.isEmpty)
        #expect(restartedHistory.entries.isEmpty)
        #expect(restartedBuffer.entries.isEmpty)
        #expect(restartedUnviewed.ids.isEmpty)
        #expect(restartedPending.entries.isEmpty)
        #expect(savedPeople.contains(target.id))
        relaunchedViewModel.stopAllBluetoothActivity()
    }

    @Test("Server block sync physically purges all encounter stores")
    @MainActor
    func serverBlockSyncPurgesAllEncounterStores() async {
        let target = NearbyUser(
            id: UUID(),
            name: "Server blocked",
            username: "@server_blocked",
            bio: nil,
            photoURL: nil
        )
        let historyStore = FakeEncounterHistoryStore()
        let bufferStore = FakeEncounterHistoryStore()
        let unviewedStore = InMemoryUnviewedEncounterStore()
        let pendingStore = InMemoryPendingEncounterIdentityStore()
        let blockedStore = FakeBlockedProfileStore()
        let response = BlockedProfileResponse(
            telescanId: target.id,
            name: target.name,
            username: target.username,
            photoUrl: target.photoURL,
            blockedAt: "2026-09-01T12:00:00Z"
        )
        let viewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            blockedProfileStore: blockedStore,
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            unviewedEncounterStore: unviewedStore,
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil,
            blockedProfilesLoader: { [response] }
        )
        historyStore.record(target, seenAt: Date())
        bufferStore.record(target, seenAt: Date())
        unviewedStore.insert(target.id)
        pendingStore.record(id: target.id, seenAt: Date())

        await viewModel.synchronizeBlockedProfiles()

        #expect(blockedStore.ids == [target.discoveryID])
        #expect(historyStore.entries.isEmpty)
        #expect(bufferStore.entries.isEmpty)
        #expect(unviewedStore.ids.isEmpty)
        #expect(pendingStore.entries.isEmpty)
        #expect(viewModel.encounterHistory.isEmpty)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("A delayed block sync cannot undo a completed local block")
    @MainActor
    func staleBlockSyncCannotUndoBlock() async throws {
        let target = NearbyUser(
            id: UUID(), name: "Target", username: "target",
            bio: nil, photoURL: nil
        )
        let response = blockedResponse(for: target, at: "new")
        let store = FakeBlockedProfileStore()
        var continuation:
            CheckedContinuation<[BlockedProfileResponse], Never>?
        let viewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            blockedProfileStore: store,
            encounterRetention: nil,
            blockedProfilesLoader: {
                await withCheckedContinuation { continuation = $0 }
            },
            blockSubmitter: { _ in response }
        )
        let sync = Task { await viewModel.synchronizeBlockedProfiles() }
        while continuation == nil { await Task.yield() }

        try await viewModel.block(target)
        continuation?.resume(returning: [])
        continuation = nil
        await sync.value

        #expect(store.ids == [target.discoveryID])
        #expect(viewModel.blockedProfiles == [response])
        viewModel.stopAllBluetoothActivity()
    }

    @Test("A delayed block sync cannot undo a completed local unblock")
    @MainActor
    func staleBlockSyncCannotUndoUnblock() async throws {
        let target = NearbyUser(
            id: UUID(), name: "Target", username: "target",
            bio: nil, photoURL: nil
        )
        let response = blockedResponse(for: target, at: "old")
        let store = FakeBlockedProfileStore()
        store.insert(target.id)
        var continuation:
            CheckedContinuation<[BlockedProfileResponse], Never>?
        let viewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            blockedProfileStore: store,
            encounterRetention: nil,
            blockedProfilesLoader: {
                await withCheckedContinuation { continuation = $0 }
            },
            unblockSubmitter: { _ in }
        )
        let sync = Task { await viewModel.synchronizeBlockedProfiles() }
        while continuation == nil { await Task.yield() }

        try await viewModel.unblock(response)
        continuation?.resume(returning: [response])
        continuation = nil
        await sync.value

        #expect(store.ids.isEmpty)
        #expect(viewModel.blockedProfiles.isEmpty)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("An older block sync cannot overwrite a newer sync")
    @MainActor
    func overlappingBlockSyncsApplyNewestResponse() async {
        let oldUser = NearbyUser(
            id: UUID(), name: "Old", username: "old",
            bio: nil, photoURL: nil
        )
        let newUser = NearbyUser(
            id: UUID(), name: "New", username: "new",
            bio: nil, photoURL: nil
        )
        let oldResponse = blockedResponse(for: oldUser, at: "old")
        let newResponse = blockedResponse(for: newUser, at: "new")
        let store = FakeBlockedProfileStore()
        var continuations: [
            CheckedContinuation<[BlockedProfileResponse], Never>
        ] = []
        let viewModel = PeopleViewModel(
            bleManager: FakeBLEManager(),
            blockedProfileStore: store,
            encounterRetention: nil,
            blockedProfilesLoader: {
                await withCheckedContinuation { continuations.append($0) }
            }
        )
        let older = Task { await viewModel.synchronizeBlockedProfiles() }
        while continuations.count < 1 { await Task.yield() }
        let newer = Task { await viewModel.synchronizeBlockedProfiles() }
        while continuations.count < 2 { await Task.yield() }

        continuations[1].resume(returning: [newResponse])
        await newer.value
        continuations[0].resume(returning: [oldResponse])
        await older.value

        #expect(store.ids == [newUser.discoveryID])
        #expect(viewModel.blockedProfiles == [newResponse])
        viewModel.stopAllBluetoothActivity()
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

        // A process interruption does not execute the explicit user-facing
        // scanning stop path, so the persisted unresolved identity remains.
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
        firstViewModel.stopAllBluetoothActivity()
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

    @Test("A late account A profile callback cannot write into account B")
    @MainActor
    func lateProfileCallbackCannotCrossAccountReset() async throws {
        let manager = FakeBLEManager()
        let accountAID = UUID()
        let accountBID = UUID()
        var accountAContinuation:
            CheckedContinuation<TelescanProfileResponse, Error>?
        let historyStore = FakeEncounterHistoryStore()
        let bufferStore = FakeEncounterHistoryStore()
        let unviewedStore = InMemoryUnviewedEncounterStore()
        let pendingStore = InMemoryPendingEncounterIdentityStore()
        let viewModel = PeopleViewModel(
            bleManager: manager,
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            unviewedEncounterStore: unviewedStore,
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil,
            encounterInactivityDelay: 30,
            profileLoader: { requestedID in
                if requestedID == accountAID {
                    return try await withCheckedThrowingContinuation {
                        continuation in
                        accountAContinuation = continuation
                    }
                }
                return TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Account B",
                    username: "account_b",
                    photoUrl: nil
                )
            }
        )

        manager.emitDiscovery(id: accountAID.uuidString, rssi: -55)
        while accountAContinuation == nil {
            await Task.yield()
        }

        viewModel.resetAccountScopedState()
        viewModel.toggleScanning(true)
        manager.emitDiscovery(id: accountBID.uuidString, rssi: -56)
        try await Task.sleep(for: .milliseconds(50))
        accountAContinuation?.resume(
            returning: TelescanProfileResponse(
                telescanId: accountAID,
                name: "Late account A",
                username: "late_account_a",
                photoUrl: nil
            )
        )
        accountAContinuation = nil
        try await Task.sleep(for: .milliseconds(50))

        #expect(viewModel.visibleUsers.map(\.id) == [accountBID])
        #expect(viewModel.userCache[accountAID.uuidString.lowercased()] == nil)
        #expect(!historyStore.entries.contains { $0.id == accountAID })
        #expect(!bufferStore.entries.contains { $0.id == accountAID })
        #expect(!unviewedStore.ids.contains(accountAID))
        #expect(!pendingStore.entries.contains { $0.id == accountAID })
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

    @Test("A queued BLE callback is rejected after scanning is disabled")
    @MainActor
    func queuedDiscoveryCannotCrossScanningDisable() async throws {
        let manager = FakeBLEManager()
        let historyStore = FakeEncounterHistoryStore()
        let bufferStore = FakeEncounterHistoryStore()
        let pendingStore = InMemoryPendingEncounterIdentityStore()
        var profileLoads = 0
        let viewModel = PeopleViewModel(
            bleManager: manager,
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil,
            profileLoader: { requestedID in
                profileLoads += 1
                return TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Late callback",
                    username: "late_callback",
                    photoUrl: nil
                )
            }
        )

        viewModel.toggleScanning(true)
        manager.emitDiscovery(id: UUID().uuidString, rssi: -55)
        viewModel.toggleScanning(false)
        try await Task.sleep(for: .milliseconds(20))

        #expect(profileLoads == 0)
        #expect(viewModel.devices.isEmpty)
        #expect(viewModel.visibleUsers.isEmpty)
        #expect(pendingStore.entries.isEmpty)
        #expect(historyStore.entries.isEmpty)
        #expect(bufferStore.entries.isEmpty)
    }

    @Test("A queued BLE callback is rejected after all BLE activity stops")
    @MainActor
    func queuedDiscoveryCannotCrossFullStop() async throws {
        let manager = FakeBLEManager()
        let historyStore = FakeEncounterHistoryStore()
        let bufferStore = FakeEncounterHistoryStore()
        let pendingStore = InMemoryPendingEncounterIdentityStore()
        var profileLoads = 0
        let viewModel = PeopleViewModel(
            bleManager: manager,
            encounterHistoryStore: historyStore,
            encounterBufferStore: bufferStore,
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil,
            profileLoader: { requestedID in
                profileLoads += 1
                return TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Late callback",
                    username: "late_callback",
                    photoUrl: nil
                )
            }
        )

        viewModel.toggleScanning(true)
        manager.emitDiscovery(id: UUID().uuidString, rssi: -55)
        viewModel.stopAllBluetoothActivity()
        try await Task.sleep(for: .milliseconds(20))

        #expect(profileLoads == 0)
        #expect(viewModel.devices.isEmpty)
        #expect(viewModel.visibleUsers.isEmpty)
        #expect(pendingStore.entries.isEmpty)
        #expect(historyStore.entries.isEmpty)
        #expect(bufferStore.entries.isEmpty)
    }

    @Test("Queued BLE callbacks cannot cross reset and scan re-enable")
    @MainActor
    func queuedBLECallbacksCannotEnterNextAccountScanEpoch() async throws {
        let manager = FakeBLEManager()
        let dispatcher = ControlledMainActorDispatcher()
        let staleDiscoveryID = UUID()
        let staleUpdateID = UUID()
        let currentID = UUID()
        var profileLoads: [UUID] = []
        let pendingStore = InMemoryPendingEncounterIdentityStore()
        let viewModel = PeopleViewModel(
            bleManager: manager,
            pendingEncounterIdentityStore: pendingStore,
            encounterRetention: nil,
            callbackDispatcher: dispatcher,
            profileLoader: { requestedID in
                profileLoads.append(requestedID)
                return TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Current account",
                    username: "current_account",
                    photoUrl: nil
                )
            }
        )

        viewModel.toggleScanning(true)
        manager.queueSourceDiscovery(id: staleDiscoveryID.uuidString, rssi: -55)
        manager.queueSourceUpdate(id: staleUpdateID.uuidString, rssi: -56)
        manager.queueSourceLoss(id: currentID.uuidString)
        manager.queueSourceFailure(APIClientError.httpStatus(503))
        #expect(manager.queuedSourceCallbackCount == 4)
        #expect(dispatcher.count == 0)

        viewModel.resetAccountScopedState()
        viewModel.toggleScanning(true)
        manager.emitDiscovery(id: currentID.uuidString, rssi: -57)

        dispatcher.runLast()
        await Task.yield()
        await Task.yield()
        #expect(viewModel.visibleUsers.map(\.id) == [currentID])

        manager.deliverQueuedSourceCallbacks()
        #expect(dispatcher.count == 4)
        dispatcher.runAll()
        await Task.yield()

        #expect(profileLoads == [currentID])
        #expect(viewModel.visibleUsers.map(\.id) == [currentID])
        #expect(
            Set(viewModel.devices.keys) == [currentID.uuidString.lowercased()]
        )
        #expect(viewModel.discoveryError == nil)
        #expect(pendingStore.entries.isEmpty)
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

    @Test("People already nearby when backgrounding do not notify")
    func alreadyNearbyPeopleBecomeNotificationBaseline() throws {
        let start = Date(timeIntervalSince1970: 2_500)
        var aggregator = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180
        )

        aggregator.markAlreadyNearby(
            ids: ["already-visible"],
            at: start
        )

        #expect(
            aggregator.detect(
                id: "already-visible",
                at: start.addingTimeInterval(1)
            ) == nil
        )
        #expect(aggregator.pendingIDs.isEmpty)

        let update = aggregator.detect(
            id: "just-arrived",
            at: start.addingTimeInterval(2)
        )
        guard case .schedule(let batch) = update else {
            Issue.record("Expected a notification for the new nearby person")
            return
        }
        #expect(batch.kind == .initial)
        #expect(batch.addedCount == 1)
        #expect(batch.totalCount == 2)
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

    @Test("Raw, invalid and timed-out identities never notify in background")
    @MainActor
    func unresolvedBackgroundIdentityDoesNotNotify() async throws {
        let manager = FakeBLEManager()
        let notifier = FakeNearbyPeopleNotifier()
        let profileID = UUID()
        let viewModel = PeopleViewModel(
            bleManager: manager,
            nearbyPeopleNotifier: notifier,
            maximumProfileResolutionAttempts: 1,
            profileLoader: { _ in
                throw URLError(.timedOut)
            }
        )

        viewModel.toggleScanning(true)
        viewModel.reconcileBluetoothState(
            isActive: false,
            scanningEnabled: true
        )
        manager.emitDiscovery(id: "not-a-uuid", rssi: -55)
        manager.emitDiscovery(id: profileID.uuidString, rssi: -55)
        try await Task.sleep(for: .milliseconds(50))

        #expect(notifier.scanningEnabled == true)
        #expect(notifier.detectedIDs.isEmpty)
        #expect(notifier.detectCalls.isEmpty)
        #expect(viewModel.visibleUsers.isEmpty)
        viewModel.stopAllBluetoothActivity()
    }

    @Test("Transient profile resolution notifies once after authenticated success")
    @MainActor
    func resolvedBackgroundProfileNotifiesOnceAfterRetry() async throws {
        let manager = FakeBLEManager()
        let notifier = FakeNearbyPeopleNotifier()
        let profileID = UUID()
        var attempts = 0
        let viewModel = PeopleViewModel(
            bleManager: manager,
            nearbyPeopleNotifier: notifier,
            maximumProfileResolutionAttempts: 3,
            profileRetryBaseDelay: 0.01,
            maximumRetryDelay: 0.02,
            profileLoader: { requestedID in
                attempts += 1
                if attempts == 1 {
                    throw APIClientError.httpStatus(503)
                }
                return TelescanProfileResponse(
                    telescanId: requestedID,
                    name: "Resolved",
                    username: "resolved",
                    photoUrl: nil
                )
            }
        )

        viewModel.toggleScanning(true)
        viewModel.reconcileBluetoothState(
            isActive: false,
            scanningEnabled: true
        )
        manager.emitDiscovery(id: profileID.uuidString, rssi: -55)
        try await Task.sleep(for: .milliseconds(150))

        let canonicalID = profileID.uuidString.lowercased()
        #expect(attempts == 2)
        #expect(viewModel.visibleUsers.map(\.id) == [profileID])
        #expect(notifier.detectedIDs == [canonicalID])
        #expect(notifier.detectCalls == [canonicalID])

        manager.emitUpdate(id: profileID.uuidString, rssi: -56)
        await Task.yield()
        await viewModel.refreshUser(telescanID: canonicalID)
        #expect(notifier.detectCalls == [canonicalID])
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

private func testTokens(account: String) -> TokenResponse {
    TokenResponse(
        accessToken: "\(account)-access",
        refreshToken: "\(account)-refresh-token-value-that-is-long-enough",
        tokenType: "bearer",
        expiresIn: 900
    )
}

private func blockedResponse(
    for user: NearbyUser,
    at blockedAt: String
) -> BlockedProfileResponse {
    BlockedProfileResponse(
        telescanId: user.id,
        name: user.name,
        username: user.username,
        photoUrl: user.photoURL,
        blockedAt: blockedAt
    )
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

private final class FaultInjectingSecureStore: SecureStoring {
    private var values: [String: Data] = [:]
    var failReads = false
    var failRemovals = false

    func data(for key: String) throws -> Data? {
        if failReads { throw SecureStoreError.invalidData }
        return values[key]
    }

    func set(_ data: Data, for key: String) throws {
        values[key] = data
    }

    func remove(_ key: String) throws {
        if failRemovals { throw SecureStoreError.invalidData }
        values.removeValue(forKey: key)
    }
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

private final class BlockingRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var started = false

    var hasStarted: Bool {
        lock.withLock { started }
    }

    func markStartedAndWait() {
        lock.withLock { started = true }
        _ = release.wait(timeout: .now() + 2)
    }

    func open() {
        release.signal()
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
    private var discoveryEventEpoch: UUID?
    private var queuedSourceCallbacks: [() -> Void] = []

    var queuedSourceCallbackCount: Int {
        queuedSourceCallbacks.count
    }

    func startScanning() { }
    func restartScanning() { }
    func stopScanning() { }
    func startAdvertising(id: String) { }
    func restartAdvertising(id: String) { }
    func stopAdvertising() { }
    func reconcileDiscoveryState() { }
    func setApplicationActive(_ isActive: Bool) { }
    func setDiscoveryEventEpoch(_ epoch: UUID?) {
        discoveryEventEpoch = epoch
    }
    func reset() { }

    func emitDiscovery(id: String, rssi: Int) {
        guard let discoveryEventEpoch else { return }
        delegate?.didDiscoverDevice(
            id: id,
            rssi: rssi,
            epoch: discoveryEventEpoch
        )
    }

    func emitUpdate(id: String, rssi: Int) {
        guard let discoveryEventEpoch else { return }
        delegate?.didUpdateDevice(
            id: id,
            rssi: rssi,
            epoch: discoveryEventEpoch
        )
    }

    func emitLoss(id: String) {
        guard let discoveryEventEpoch else { return }
        delegate?.didLoseDevice(id: id, epoch: discoveryEventEpoch)
    }

    func emitFailure(_ error: Error) {
        guard let discoveryEventEpoch else { return }
        delegate?.didFail(with: error, epoch: discoveryEventEpoch)
    }

    func queueSourceDiscovery(id: String, rssi: Int) {
        guard let discoveryEventEpoch else { return }
        queuedSourceCallbacks.append { [weak self] in
            self?.delegate?.didDiscoverDevice(
                id: id,
                rssi: rssi,
                epoch: discoveryEventEpoch
            )
        }
    }

    func queueSourceUpdate(id: String, rssi: Int) {
        guard let discoveryEventEpoch else { return }
        queuedSourceCallbacks.append { [weak self] in
            self?.delegate?.didUpdateDevice(
                id: id,
                rssi: rssi,
                epoch: discoveryEventEpoch
            )
        }
    }

    func queueSourceLoss(id: String) {
        guard let discoveryEventEpoch else { return }
        queuedSourceCallbacks.append { [weak self] in
            self?.delegate?.didLoseDevice(
                id: id,
                epoch: discoveryEventEpoch
            )
        }
    }

    func queueSourceFailure(_ error: Error) {
        guard let discoveryEventEpoch else { return }
        queuedSourceCallbacks.append { [weak self] in
            self?.delegate?.didFail(
                with: error,
                epoch: discoveryEventEpoch
            )
        }
    }

    func deliverQueuedSourceCallbacks() {
        let callbacks = queuedSourceCallbacks
        queuedSourceCallbacks.removeAll()
        for callback in callbacks {
            callback()
        }
    }
}

private final class ControlledMainActorDispatcher:
    BLECallbackDispatching,
    @unchecked Sendable
{
    typealias Operation = @MainActor @Sendable () -> Void

    private let lock = NSLock()
    private var operations: [Operation] = []

    var count: Int {
        lock.withLock { operations.count }
    }

    func dispatch(_ operation: @escaping Operation) {
        lock.withLock { operations.append(operation) }
    }

    @MainActor
    func runLast() {
        let operation = lock.withLock { operations.popLast() }
        operation?()
    }

    @MainActor
    func runAll() {
        let pending = lock.withLock {
            let pending = operations
            operations.removeAll()
            return pending
        }
        for operation in pending {
            operation()
        }
    }
}

@MainActor
private final class FakeNearbyPeopleNotifier: NearbyPeopleNotifying {
    private(set) var synchronizedIDs: Set<String> = []
    private(set) var detectedIDs: Set<String> = []
    private(set) var detectCalls: [String] = []
    private(set) var lostIDs: Set<String> = []
    private(set) var resetCount = 0
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
        detectCalls.append(id)
    }
    func lose(id: String) {
        detectedIDs.remove(id)
        lostIDs.insert(id)
    }
    func reset() {
        resetCount += 1
        synchronizedIDs.removeAll()
        detectedIDs.removeAll()
    }
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
