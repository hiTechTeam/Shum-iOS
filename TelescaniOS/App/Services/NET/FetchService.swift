import Foundation

final class FetchService {
    static let fetch = FetchService()

    private let client: APIClient

    init(client: APIClient = .shared) {
        self.client = client
    }

    func signInWithApple(
        identityToken: String,
        nonce: String,
        name: String?
    ) async throws -> AuthenticatedAccountResponse {
        try await client.signInWithApple(
            identityToken: identityToken,
            nonce: nonce,
            name: name
        )
    }

    func linkTelegram(code: String) async throws -> TelegramLinkResponse {
        try await client.linkTelegram(code: code)
    }

    func currentProfile() async throws -> TelescanProfileResponse {
        try await client.currentProfile()
    }

    func profile(telescanID: UUID) async throws -> TelescanProfileResponse {
        try await client.profile(id: telescanID)
    }

    func updateProfile(bio: String?) async throws -> TelescanProfileResponse {
        try await client.updateProfile(bio: bio)
    }

    func submitReport(
        targetID: UUID,
        reason: ReportReason,
        details: String?
    ) async throws -> ReportResponse {
        try await client.submitReport(
            targetID: targetID,
            reason: reason,
            details: details
        )
    }

    func blockProfile(telescanID: UUID) async throws -> BlockedProfileResponse {
        try await client.blockProfile(id: telescanID)
    }

    func blockedProfiles() async throws -> [BlockedProfileResponse] {
        try await client.blockedProfiles()
    }

    func unblockProfile(telescanID: UUID) async throws {
        try await client.unblockProfile(id: telescanID)
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
