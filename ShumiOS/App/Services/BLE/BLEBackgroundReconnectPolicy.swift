import Foundation

/// Small, deterministic policies used by the Core Bluetooth owner when the
/// application moves to the background. Keeping them free of Core Bluetooth
/// types makes the selection rules unit-testable without a physical radio.
enum BLEBackgroundReconnectPolicy {
    static func candidateIDs<ID: Hashable>(
        lastSeenAt: [ID: Date],
        excluding excludedIDs: Set<ID>,
        now: Date,
        maximumAge: TimeInterval,
        limit: Int
    ) -> [ID] {
        guard limit > 0, maximumAge > 0 else { return [] }

        return lastSeenAt
            .filter { id, date in
                !excludedIDs.contains(id)
                    && now.timeIntervalSince(date) >= 0
                    && now.timeIntervalSince(date) <= maximumAge
            }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    /// Both phones can initiate a connection at the same time. A stable UUID
    /// ordering lets only one side retain the idle background link, avoiding
    /// duplicate connections while preserving the bidirectional identity flow.
    static func shouldRetainConnection(
        localIdentity: UUID,
        peerIdentity: UUID
    ) -> Bool {
        guard localIdentity != peerIdentity else { return false }
        return localIdentity.uuidString < peerIdentity.uuidString
    }
}
