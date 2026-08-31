import Foundation

struct AppleSignInRequest: Encodable {
    let identityToken: String
    let nonce: String
    let deviceId: UUID
    let name: String?
}

struct LinkDeviceRequest: Encodable {
    let code: String
    let deviceId: UUID
}

struct TelegramLinkRequest: Encodable {
    let code: String
}

struct RefreshTokenRequest: Encodable {
    let refreshToken: String
}

struct ProfileUpdateRequest: Encodable {
    let bio: String?

    private enum CodingKeys: String, CodingKey {
        case bio
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let bio {
            try container.encode(bio, forKey: .bio)
        } else {
            try container.encodeNil(forKey: .bio)
        }
    }
}

struct ReportCreateRequest: Encodable {
    let clientRequestId: UUID
    let targetTelescanId: UUID
    let details: String?
    private let reason = "other"
}
