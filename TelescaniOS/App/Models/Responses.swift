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
    let photoUrl: String?
}

struct LinkDeviceResponse: Codable, Equatable {
    let tokens: TokenResponse
    let profile: TelescanProfileResponse
}

struct ConfirmationRequestResponse: Codable, Equatable {
    let confirmationId: UUID
    let status: String
}
