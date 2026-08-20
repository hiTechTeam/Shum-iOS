import Foundation

struct LinkDeviceRequest: Encodable {
    let code: String
    let deviceId: UUID
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

enum ReportReason: String, Codable, CaseIterable {
    case spam
    case harassment
    case inappropriate
    case impersonation
    case other
}

struct ReportCreateRequest: Encodable {
    let clientRequestId: UUID
    let targetTelescanId: UUID
    let reason: ReportReason
    let details: String?
}
