import Foundation

protocol BlockedProfileStoring: AnyObject {
    var ids: Set<String> { get }
    func replace(with ids: Set<String>)
    func insert(_ id: UUID)
    func remove(_ id: UUID)
    func removeAll()
}

final class BlockedProfileStore: BlockedProfileStoring {
    static let shared = BlockedProfileStore()

    private let defaults: UserDefaults
    private let key = "telescan.blocked-profile-ids"
    private(set) var ids: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set(defaults.stringArray(forKey: key) ?? [])
    }

    func replace(with ids: Set<String>) {
        self.ids = ids
        persist()
    }

    func insert(_ id: UUID) {
        ids.insert(Self.canonical(id))
        persist()
    }

    func remove(_ id: UUID) {
        ids.remove(Self.canonical(id))
        persist()
    }

    func removeAll() {
        ids.removeAll()
        defaults.removeObject(forKey: key)
    }

    private func persist() {
        defaults.set(ids.sorted(), forKey: key)
    }

    private static func canonical(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }
}
