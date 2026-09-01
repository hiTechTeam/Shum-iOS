import Foundation

enum APIClientError: Error {
    case invalidURL
    case unauthenticated
    case accountNotFound
    case telegramUsernameRequired
    case invalidResponse
    case httpStatus(Int)
}

private struct APIErrorResponse: Decodable {
    let code: String?
}

actor APIClient {
    static let shared = APIClient(
        baseURL: URL(string: AppConfig.apiOrigin)!,
        sessionStore: .shared
    )

    private let baseURL: URL
    private let session: URLSession
    private let sessionStore: AuthSessionStore
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var refreshTask: (generation: UUID, task: Task<Void, Error>)?

    init(
        baseURL: URL,
        session: URLSession = .shared,
        sessionStore: AuthSessionStore
    ) {
        self.baseURL = baseURL
        self.session = session
        self.sessionStore = sessionStore
    }

    func signInWithApple(
        identityToken: String,
        nonce: String,
        name: String?
    ) async throws -> AuthenticatedAccountResponse {
        let generation = sessionStore.credentialGeneration
        let deviceID = try sessionStore.installationDeviceID()
        let request = try jsonRequest(
            path: "/api/v1/auth/apple",
            method: "POST",
            body: AppleSignInRequest(
                identityToken: identityToken,
                nonce: nonce,
                deviceId: deviceID,
                name: name
            )
        )
        let data = try await perform(request, authenticated: false)
        let response = try decoder.decode(AuthenticatedAccountResponse.self, from: data)
        guard try sessionStore.saveAppleSession(
            response.tokens,
            ifGenerationMatches: generation
        ) else {
            throw APIClientError.unauthenticated
        }
        return response
    }

    #if TELESCAN_PERSONAL_TEAM
    func linkForDevelopment(code: String) async throws -> TelegramLinkResponse {
        let generation = sessionStore.credentialGeneration
        let deviceID = try sessionStore.installationDeviceID()
        let request = try jsonRequest(
            path: "/api/v1/auth/link",
            method: "POST",
            body: LinkDeviceRequest(code: code, deviceId: deviceID)
        )
        let data = try await perform(request, authenticated: false)
        let response = try decoder.decode(AuthenticatedAccountResponse.self, from: data)
        guard try sessionStore.saveLegacySession(
            response.tokens,
            ifGenerationMatches: generation
        ) else {
            throw APIClientError.unauthenticated
        }
        return TelegramLinkResponse(
            access: AccessTokenResponse(
                accessToken: response.tokens.accessToken,
                tokenType: response.tokens.tokenType,
                expiresIn: response.tokens.expiresIn
            ),
            profile: response.profile
        )
    }

    func linkTelegramForPersonalTeam(code: String) async throws
        -> TelegramLinkResponse {
        if sessionStore.hasPrimarySession {
            return try await linkTelegram(code: code)
        }
        return try await linkForDevelopment(code: code)
    }
    #endif

    func linkTelegram(code: String) async throws -> TelegramLinkResponse {
        let generation = sessionStore.credentialGeneration
        let request = try jsonRequest(
            path: "/api/v1/users/me/telegram/link",
            method: "POST",
            body: TelegramLinkRequest(code: code)
        )
        let data = try await perform(
            request,
            authenticated: true,
            expectedGeneration: generation
        )
        let response = try decoder.decode(TelegramLinkResponse.self, from: data)
        guard try sessionStore.saveAccessToken(
            response.access.accessToken,
            ifGenerationMatches: generation
        ) else {
            throw APIClientError.unauthenticated
        }
        return response
    }

    func currentProfile() async throws -> TelescanProfileResponse {
        try await decode(path: "/api/v1/users/me")
    }

    func profile(id: UUID) async throws -> TelescanProfileResponse {
        try await decode(path: "/api/v1/profiles/\(id.uuidString.lowercased())")
    }

    func updateProfile(bio: String?) async throws -> TelescanProfileResponse {
        let request = try jsonRequest(
            path: "/api/v1/users/me",
            method: "PATCH",
            body: ProfileUpdateRequest(bio: bio)
        )
        return try decoder.decode(
            TelescanProfileResponse.self,
            from: try await perform(request, authenticated: true)
        )
    }

    func submitReport(
        targetID: UUID,
        details: String?,
        requestID: UUID
    ) async throws -> ReportResponse {
        let normalizedDetails = try ReportCommentPolicy.normalized(details)
        let request = try jsonRequest(
            path: "/api/v1/reports",
            method: "POST",
            body: ReportCreateRequest(
                clientRequestId: requestID,
                targetTelescanId: targetID,
                details: normalizedDetails
            )
        )
        return try decoder.decode(
            ReportResponse.self,
            from: try await perform(request, authenticated: true)
        )
    }

    func blockProfile(id: UUID) async throws -> BlockedProfileResponse {
        let request = try request(
            path: "/api/v1/users/me/blocks/\(id.uuidString.lowercased())",
            method: "PUT"
        )
        return try decoder.decode(
            BlockedProfileResponse.self,
            from: try await perform(request, authenticated: true)
        )
    }

    func blockedProfiles() async throws -> [BlockedProfileResponse] {
        try await decode(path: "/api/v1/users/me/blocks")
    }

    func unblockProfile(id: UUID) async throws {
        let request = try request(
            path: "/api/v1/users/me/blocks/\(id.uuidString.lowercased())",
            method: "DELETE"
        )
        _ = try await perform(request, authenticated: true)
    }

    func replacePhoto(_ data: Data) async throws -> TelescanProfileResponse {
        let boundary = "TelescanBoundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"profile.jpg\"\r\n")
        body.append("Content-Type: image/jpeg\r\n\r\n")
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n")
        var request = try request(path: "/api/v1/users/me/photo", method: "PUT")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = body
        let response = try await perform(request, authenticated: true)
        return try decoder.decode(TelescanProfileResponse.self, from: response)
    }

    func deletePhoto() async throws {
        let request = try request(path: "/api/v1/users/me/photo", method: "DELETE")
        _ = try await perform(request, authenticated: true)
    }

    func logoutCurrentSession() async throws {
        guard let accessToken = sessionStore.accessToken else {
            throw APIClientError.unauthenticated
        }
        try await logoutCurrentSession(accessToken: accessToken)
    }

    func logoutCurrentSession(accessToken: String) async throws {
        let request = try request(path: "/api/v1/auth/session", method: "DELETE")
        var authenticatedRequest = request
        authenticatedRequest.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        _ = try await perform(authenticatedRequest, authenticated: false)
    }

    func deleteAccount() async throws {
        let request = try request(path: "/api/v1/users/me", method: "DELETE")
        _ = try await perform(request, authenticated: true)
    }

    private func decode<T: Decodable>(path: String) async throws -> T {
        let request = try request(path: path, method: "GET")
        return try decoder.decode(
            T.self,
            from: try await perform(request, authenticated: true)
        )
    }

    private func perform(
        _ original: URLRequest,
        authenticated: Bool,
        retryAfterRefresh: Bool = true,
        expectedGeneration: UUID? = nil
    ) async throws -> Data {
        var request = original
        var requestGeneration: UUID?
        var requestAccessToken: String?
        if authenticated {
            let credentials = sessionStore.credentials
            guard expectedGeneration == nil
                    || credentials.generation == expectedGeneration,
                  let token = credentials.accessToken else {
                throw APIClientError.unauthenticated
            }
            requestGeneration = credentials.generation
            requestAccessToken = token
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        if authenticated,
           let requestGeneration,
           sessionStore.credentialGeneration != requestGeneration {
            throw APIClientError.unauthenticated
        }
        if http.statusCode == 401 && authenticated && retryAfterRefresh {
            guard let requestGeneration else {
                throw APIClientError.unauthenticated
            }
            let currentCredentials = sessionStore.credentials
            if currentCredentials.generation == requestGeneration,
               currentCredentials.accessToken != nil,
               currentCredentials.accessToken != requestAccessToken {
                return try await perform(
                    original,
                    authenticated: true,
                    retryAfterRefresh: false,
                    expectedGeneration: requestGeneration
                )
            }
            try await refreshTokens(expectedGeneration: requestGeneration)
            return try await perform(
                original,
                authenticated: true,
                retryAfterRefresh: false,
                expectedGeneration: requestGeneration
            )
        }
        if http.statusCode == 401 && authenticated {
            if let requestGeneration {
                sessionStore.clearTokens(
                    ifGenerationMatches: requestGeneration
                )
            }
            throw APIClientError.unauthenticated
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404,
               request.httpMethod == "GET",
               request.url?.path == "/api/v1/users/me" {
                throw APIClientError.accountNotFound
            }
            if http.statusCode == 422,
               let payload = try? decoder.decode(APIErrorResponse.self, from: data),
               payload.code == "telegram_username_required" {
                throw APIClientError.telegramUsernameRequired
            }
            throw APIClientError.httpStatus(http.statusCode)
        }
        return data
    }

    private func refreshTokens(expectedGeneration: UUID) async throws {
        if let refreshTask,
           refreshTask.generation == expectedGeneration {
            try await refreshTask.task.value
            return
        }
        let credentials = sessionStore.credentials
        guard credentials.generation == expectedGeneration,
              let refreshToken = credentials.refreshToken else {
            throw APIClientError.unauthenticated
        }
        let task = Task {
            try await self.performRefreshRequest(
                refreshToken,
                generation: expectedGeneration
            )
        }
        refreshTask = (expectedGeneration, task)
        defer {
            if refreshTask?.generation == expectedGeneration {
                refreshTask = nil
            }
        }
        try await task.value
    }

    private func performRefreshRequest(
        _ refreshToken: String,
        generation: UUID
    ) async throws {
        let request = try jsonRequest(
            path: "/api/v1/auth/refresh",
            method: "POST",
            body: RefreshTokenRequest(refreshToken: refreshToken)
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        if http.statusCode == 401 {
            sessionStore.clearTokens(ifGenerationMatches: generation)
            throw APIClientError.unauthenticated
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIClientError.httpStatus(http.statusCode)
        }
        guard try sessionStore.save(
            try decoder.decode(TokenResponse.self, from: data),
            ifGenerationMatches: generation
        ) else {
            throw APIClientError.unauthenticated
        }
    }

    private func jsonRequest<T: Encodable>(
        path: String,
        method: String,
        body: T
    ) throws -> URLRequest {
        var request = try request(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func request(path: String, method: String) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw APIClientError.invalidURL
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15
        )
        request.httpMethod = method
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        return request
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
