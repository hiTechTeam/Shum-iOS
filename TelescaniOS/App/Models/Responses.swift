import Foundation

struct TokenResponse: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
}

struct TelescanProfileResponse: Codable, Equatable {
    let telescanId: UUID
    let name: String?
    let username: String?
    let bio: String?
    let photoUrl: String?

    init(
        telescanId: UUID,
        name: String?,
        username: String?,
        bio: String? = nil,
        photoUrl: String?
    ) {
        self.telescanId = telescanId
        self.name = name
        self.username = username
        self.bio = bio
        self.photoUrl = photoUrl
    }
}

struct LinkDeviceResponse: Codable, Equatable {
    let tokens: TokenResponse
    let profile: TelescanProfileResponse
}

struct ReportResponse: Codable, Equatable {
    let reportId: UUID
    let status: String
    let createdAt: String
}

struct BlockedProfileResponse: Codable, Equatable, Identifiable {
    let telescanId: UUID
    let name: String?
    let username: String?
    let photoUrl: String?
    let blockedAt: String

    var id: UUID { telescanId }
}
