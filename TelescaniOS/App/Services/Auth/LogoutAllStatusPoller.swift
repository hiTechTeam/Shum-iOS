import Foundation

enum LogoutAllResolution: Equatable {
    case confirmed
    case cancelled
    case expired
}

@MainActor
struct LogoutAllStatusPoller {
    private let retryDelay: Duration
    private let maximumAttempts: Int
    private let sessionProbeAction: @MainActor () async throws -> Void
    private let statusAction: @MainActor (
        UUID
    ) async throws -> ConfirmationRequestResponse

    init(
        retryDelay: Duration = .seconds(1),
        maximumAttempts: Int = 310,
        sessionProbeAction: @escaping @MainActor () async throws -> Void = {
            _ = try await FetchService.fetch.currentProfile()
        },
        statusAction: @escaping @MainActor (
            UUID
        ) async throws -> ConfirmationRequestResponse = {
            try await FetchService.fetch.logoutAllStatus(confirmationID: $0)
        }
    ) {
        self.retryDelay = retryDelay
        self.maximumAttempts = maximumAttempts
        self.sessionProbeAction = sessionProbeAction
        self.statusAction = statusAction
    }

    func wait(for confirmationID: UUID) async -> LogoutAllResolution? {
        var attempts = 0
        var usesSessionProbe = false

        while !Task.isCancelled, attempts < maximumAttempts {
            attempts += 1
            do {
                if usesSessionProbe {
                    try await sessionProbeAction()
                } else {
                    let response = try await statusAction(confirmationID)
                    switch response.status {
                    case .pending:
                        break
                    case .confirmed:
                        return .confirmed
                    case .cancelled:
                        return .cancelled
                    case .expired:
                        return .expired
                    }
                }
            } catch APIClientError.unauthenticated {
                // Confirmation revokes the session before the next status poll.
                return .confirmed
            } catch APIClientError.httpStatus(let status)
                where status == 404 && !usesSessionProbe {
                // Older API deployments do not expose confirmation status.
                // Fall back to probing the protected current-user endpoint.
                usesSessionProbe = true
                continue
            } catch is CancellationError {
                return nil
            } catch {
                // Temporary connectivity failures are retried until the
                // authoritative confirmation reaches a terminal state.
            }

            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                return nil
            }
        }
        return Task.isCancelled ? nil : .expired
    }
}
