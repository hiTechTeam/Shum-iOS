import Foundation

struct LinkDeviceRequest: Encodable {
    let code: String
    let deviceId: UUID
}

struct RefreshTokenRequest: Encodable {
    let refreshToken: String
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
