import Foundation

enum SessionValidationResult: Equatable {
    case active(TelescanProfileResponse)
    case invalid
    case unavailable
}

@MainActor
struct SessionValidator {
    private let profileAction: @MainActor () async throws -> TelescanProfileResponse

    init(
        profileAction: @escaping @MainActor () async throws
            -> TelescanProfileResponse = {
                try await FetchService.fetch.currentProfile()
            }
    ) {
        self.profileAction = profileAction
    }

    func validate() async -> SessionValidationResult {
        do {
            let profile = try await profileAction()
            guard let username = profile.username?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !username.isEmpty else {
                return .invalid
            }
            return .active(profile)
        } catch APIClientError.unauthenticated {
            return .invalid
        } catch APIClientError.accountNotFound {
            return .invalid
        } catch is CancellationError {
            return .unavailable
        } catch {
            return .unavailable
        }
    }
}
