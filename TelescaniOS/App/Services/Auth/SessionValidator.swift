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
            return .active(try await profileAction())
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
