import Foundation

struct LinkDeviceRequest: Encodable {
    let code: String
    let deviceId: UUID
}

struct RefreshTokenRequest: Encodable {
    let refreshToken: String
}
