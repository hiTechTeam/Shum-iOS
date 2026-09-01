import Foundation

protocol EncounterHistoryStoring: AnyObject {
    var entries: [EncounterHistoryEntry] { get }

    func record(_ user: NearbyUser, seenAt: Date)
    func remove(ids: Set<UUID>)
    func prune(olderThan cutoff: Date)
    func removeAll()
}

protocol UnviewedEncounterStoring: AnyObject {
    var ids: Set<UUID> { get }

    func insert(_ id: UUID)
    func remove(_ id: UUID)
    func retain(_ ids: Set<UUID>)
    func removeAll()
}

final class UnviewedEncounterStore: UnviewedEncounterStoring {
    static let shared = UnviewedEncounterStore()

    private let defaults: UserDefaults
    private let key: String

    private(set) var ids: Set<UUID>

    init(
        defaults: UserDefaults = .standard,
        key: String = "telescan.unviewed-encounters.v1"
    ) {
        self.defaults = defaults
        self.key = key
        ids = Set(
            defaults.stringArray(forKey: key)?
                .compactMap(UUID.init(uuidString:)) ?? []
        )
    }

    func insert(_ id: UUID) {
        guard ids.insert(id).inserted else { return }
        persist()
    }

    func remove(_ id: UUID) {
        guard ids.remove(id) != nil else { return }
        persist()
    }

    func retain(_ ids: Set<UUID>) {
        let retained = self.ids.intersection(ids)
        guard retained != self.ids else { return }
        self.ids = retained
        persist()
    }

    func removeAll() {
        ids.removeAll()
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        guard !ids.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}

final class InMemoryUnviewedEncounterStore: UnviewedEncounterStoring {
    private(set) var ids: Set<UUID> = []

    func insert(_ id: UUID) {
        ids.insert(id)
    }

    func remove(_ id: UUID) {
        ids.remove(id)
    }

    func retain(_ ids: Set<UUID>) {
        self.ids.formIntersection(ids)
    }

    func removeAll() {
        ids.removeAll()
    }
}

struct PendingEncounterIdentity: Identifiable, Codable, Equatable {
    let id: UUID
    let lastSeen: Date
}

protocol PendingEncounterIdentityStoring: AnyObject {
    var entries: [PendingEncounterIdentity] { get }

    func record(id: UUID, seenAt: Date)
    func remove(ids: Set<UUID>)
    func prune(olderThan cutoff: Date)
    func removeAll()
}

final class PendingEncounterIdentityStore: PendingEncounterIdentityStoring {
    static let shared = PendingEncounterIdentityStore()

    private let defaults: UserDefaults
    private let key: String
    private let maximumEntries: Int

    private(set) var entries: [PendingEncounterIdentity]

    init(
        defaults: UserDefaults = .standard,
        key: String = "telescan.pending-encounter-identities.v1",
        maximumEntries: Int = 500
    ) {
        self.defaults = defaults
        self.key = key
        self.maximumEntries = max(1, maximumEntries)

        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(
               [PendingEncounterIdentity].self,
               from: data
           ) {
            entries = Self.normalized(decoded, limit: self.maximumEntries)
        } else {
            entries = []
        }
    }

    func record(id: UUID, seenAt: Date) {
        let previousDate = entries.first { $0.id == id }?.lastSeen
        entries.removeAll { $0.id == id }
        entries.append(
            PendingEncounterIdentity(
                id: id,
                lastSeen: max(previousDate ?? seenAt, seenAt)
            )
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
        _ entries: [PendingEncounterIdentity],
        limit: Int
    ) -> [PendingEncounterIdentity] {
        var latestByID: [UUID: PendingEncounterIdentity] = [:]
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

final class InMemoryPendingEncounterIdentityStore:
    PendingEncounterIdentityStoring {

    private(set) var entries: [PendingEncounterIdentity] = []

    func record(id: UUID, seenAt: Date) {
        let previousDate = entries.first { $0.id == id }?.lastSeen
        entries.removeAll { $0.id == id }
        entries.append(
            PendingEncounterIdentity(
                id: id,
                lastSeen: max(previousDate ?? seenAt, seenAt)
            )
        )
        entries.sort { $0.lastSeen > $1.lastSeen }
    }

    func remove(ids: Set<UUID>) {
        entries.removeAll { ids.contains($0.id) }
    }

    func prune(olderThan cutoff: Date) {
        entries.removeAll { $0.lastSeen < cutoff }
    }

    func removeAll() {
        entries.removeAll()
    }
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

final class EncounterBufferStore: EncounterHistoryStoring {
    static let shared = EncounterBufferStore()

    private let storage: EncounterHistoryStore

    var entries: [EncounterHistoryEntry] {
        storage.entries
    }

    init(
        defaults: UserDefaults = .standard,
        key: String = "telescan.encounter-buffer.v1",
        maximumEntries: Int = .max
    ) {
        storage = EncounterHistoryStore(
            defaults: defaults,
            key: key,
            maximumEntries: maximumEntries
        )
    }

    func record(_ user: NearbyUser, seenAt: Date) {
        storage.record(user, seenAt: seenAt)
    }

    func remove(ids: Set<UUID>) {
        storage.remove(ids: ids)
    }

    func prune(olderThan cutoff: Date) {
        storage.prune(olderThan: cutoff)
    }

    func removeAll() {
        storage.removeAll()
    }
}
