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

enum ReportCommentValidationError: Error, Equatable {
    case tooLong(maximum: Int)
}

enum ReportCommentPolicy {
    static let maximumLength = 500

    static func normalized(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard trimmed.count <= maximumLength else {
            throw ReportCommentValidationError.tooLong(
                maximum: maximumLength
            )
        }
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ReportCreateRequest: Encodable {
    let clientRequestId: UUID
    let targetTelescanId: UUID
    let details: String?
    private let reason = "other"
}
