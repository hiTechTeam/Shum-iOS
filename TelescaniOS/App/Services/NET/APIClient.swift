import Foundation

enum APIClientError: Error {
    case invalidURL
    case unauthenticated
    case accountNotFound
    case invalidResponse
    case httpStatus(Int)
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
    private var refreshTask: Task<Void, Error>?

    init(
        baseURL: URL,
        session: URLSession = .shared,
        sessionStore: AuthSessionStore
    ) {
        self.baseURL = baseURL
        self.session = session
        self.sessionStore = sessionStore
    }

    func link(code: String) async throws -> LinkDeviceResponse {
        let deviceID = try sessionStore.installationDeviceID()
        let request = try jsonRequest(
            path: "/api/v1/auth/link",
            method: "POST",
            body: LinkDeviceRequest(code: code, deviceId: deviceID)
        )
        let data = try await perform(request, authenticated: false)
        let response = try decoder.decode(LinkDeviceResponse.self, from: data)
        try sessionStore.save(response.tokens)
        return response
    }

    func currentProfile() async throws -> TelescanProfileResponse {
        try await decode(path: "/api/v1/users/me")
    }

    func profile(id: UUID) async throws -> TelescanProfileResponse {
        try await decode(path: "/api/v1/profiles/\(id.uuidString.lowercased())")
    }

    func submitReport(
        targetID: UUID,
        reason: ReportReason,
        details: String?,
        requestID: UUID = UUID()
    ) async throws -> ReportResponse {
        let request = try jsonRequest(
            path: "/api/v1/reports",
            method: "POST",
            body: ReportCreateRequest(
                clientRequestId: requestID,
                targetTelescanId: targetID,
                reason: reason,
                details: details
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
        let request = try request(path: "/api/v1/auth/session", method: "DELETE")
        _ = try await perform(request, authenticated: true)
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
        retryAfterRefresh: Bool = true
    ) async throws -> Data {
        var request = original
        if authenticated {
            guard let token = sessionStore.accessToken else {
                throw APIClientError.unauthenticated
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIClientError.invalidResponse
        }
        if http.statusCode == 401 && authenticated && retryAfterRefresh {
            try await refreshTokens()
            return try await perform(
                original,
                authenticated: true,
                retryAfterRefresh: false
            )
        }
        if http.statusCode == 401 && authenticated {
            sessionStore.clearTokens()
            throw APIClientError.unauthenticated
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 404,
               request.httpMethod == "GET",
               request.url?.path == "/api/v1/users/me" {
                throw APIClientError.accountNotFound
            }
            throw APIClientError.httpStatus(http.statusCode)
        }
        return data
    }

    private func refreshTokens() async throws {
        if let refreshTask {
            try await refreshTask.value
            return
        }
        guard let refreshToken = sessionStore.refreshToken else {
            throw APIClientError.unauthenticated
        }
        let task = Task { try await self.performRefreshRequest(refreshToken) }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performRefreshRequest(_ refreshToken: String) async throws {
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
            sessionStore.clearTokens()
            throw APIClientError.unauthenticated
        }
        guard (200...299).contains(http.statusCode) else {
            throw APIClientError.httpStatus(http.statusCode)
        }
        try sessionStore.save(try decoder.decode(TokenResponse.self, from: data))
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
