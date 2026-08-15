import Foundation

final class FetchService {
    static let fetch = FetchService()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func link(code: String) async throws -> LinkDeviceResponse {
        try await client.link(code: code)
    }

    func currentProfile() async throws -> TelescanProfileResponse {
        try await client.currentProfile()
    }

    func profile(telescanID: UUID) async throws -> TelescanProfileResponse {
        try await client.profile(id: telescanID)
    }

    func updateProfileImage(data: Data) async throws -> TelescanProfileResponse {
        try await client.replacePhoto(data)
    }

    func deleteProfileImage() async throws {
        try await client.deletePhoto()
    }

    func logoutCurrentSession() async throws {
        try await client.logoutCurrentSession()
    }

    func deleteAccount() async throws {
        try await client.deleteAccount()
    }
}
