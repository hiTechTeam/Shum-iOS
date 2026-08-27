import Foundation

protocol EncounterHistoryStoring: AnyObject {
    var entries: [EncounterHistoryEntry] { get }

    func record(_ user: NearbyUser, seenAt: Date)
    func remove(ids: Set<UUID>)
    func prune(olderThan cutoff: Date)
    func removeAll()
}

final class EncounterHistoryStore: EncounterHistoryStoring {
    static let shared = EncounterHistoryStore()

    private let defaults: UserDefaults
    private let key: String
    private let maximumEntries: Int

    private(set) var entries: [EncounterHistoryEntry]

    init(
        defaults: UserDefaults = .standard,
        key: String = "telescan.encounter-history.v1",
        maximumEntries: Int = .max
    ) {
        self.defaults = defaults
        self.key = key
        self.maximumEntries = max(1, maximumEntries)

        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(
               [EncounterHistoryEntry].self,
               from: data
           ) {
            entries = Self.normalized(decoded, limit: self.maximumEntries)
        } else {
            entries = []
        }
    }

    func record(_ user: NearbyUser, seenAt: Date) {
        let previous = entries.first { $0.id == user.id }
        let effectiveDate = max(previous?.lastSeen ?? seenAt, seenAt)

        entries.removeAll { $0.id == user.id }
        entries.append(
            EncounterHistoryEntry(user: user, lastSeen: effectiveDate)
        )
        entries = Self.normalized(entries, limit: maximumEntries)
        persist()
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let previousCount = entries.count
        entries.removeAll { ids.contains($0.id) }
        guard entries.count != previousCount else { return }
        persist()
    }

    func prune(olderThan cutoff: Date) {
        let previousCount = entries.count
        entries.removeAll { $0.lastSeen < cutoff }
        guard entries.count != previousCount else { return }
        persist()
    }

    func removeAll() {
        entries.removeAll()
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: key)
    }

    private static func normalized(
        _ entries: [EncounterHistoryEntry],
        limit: Int
    ) -> [EncounterHistoryEntry] {
        var latestByID: [UUID: EncounterHistoryEntry] = [:]
        for entry in entries {
            if let existing = latestByID[entry.id],
               existing.lastSeen > entry.lastSeen {
                continue
            }
            latestByID[entry.id] = entry
        }

        return latestByID.values
            .sorted { lhs, rhs in
                if lhs.lastSeen == rhs.lastSeen {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.lastSeen > rhs.lastSeen
            }
            .prefix(limit)
            .map { $0 }
    }
}
