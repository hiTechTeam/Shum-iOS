import Combine
import Foundation

/// Where one profile keeps its keys and files on this iPhone. The first
/// profile keeps the names it always had; every other profile adds its ID to
/// its Keychain names and keeps its files in its own folder.
struct ShumProfileSpace: Equatable, Sendable {
    /// Empty for the first profile.
    let id: String

    static let first = ShumProfileSpace(id: "")

    /// The open profile.
    static var active: ShumProfileSpace {
        ShumProfileSpace(id: UserDefaults.standard.string(forKey: ShumProfileList.activeKey) ?? "")
    }

    /// This profile's name for a Keychain item or a setting.
    func key(_ name: String) -> String {
        id.isEmpty ? name : "\(name).\(id)"
    }

    /// The folder this profile's files live in.
    var root: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return id.isEmpty
            ? support
            : support.appendingPathComponent("Profiles", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
}

/// The profiles on this iPhone and which one is open. Each has its own keys,
/// contacts and chats; only the open one runs.
@MainActor
final class ShumProfileList: ObservableObject {
    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        var name: String
        var avatarSeed: UInt64?
    }

    static let shared = ShumProfileList()
    nonisolated static let activeKey = "shum.profiles.active"
    private static let listKey = "shum.profiles.v1"

    @Published private(set) var entries: [Entry]
    @Published private(set) var active: String

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = defaults.data(forKey: Self.listKey)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        active = defaults.string(forKey: Self.activeKey) ?? ""
    }

    var activeSpace: ShumProfileSpace { ShumProfileSpace(id: active) }

    /// Keeps the open profile's name and avatar for the list.
    func update(name: String, avatarSeed: UInt64?) {
        let entry = Entry(id: active, name: name, avatarSeed: avatarSeed)
        if let index = entries.firstIndex(where: { $0.id == active }) {
            guard entries[index] != entry else { return }
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        save()
    }

    /// A new profile's space; it joins the list once it has its card.
    func newSpace() -> ShumProfileSpace {
        ShumProfileSpace(id: UUID().uuidString.lowercased())
    }

    func add(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entries.append(entry)
        save()
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Makes `id` the open profile; the app then reopens on it.
    func activate(_ id: String) {
        active = id
        defaults.set(id, forKey: Self.activeKey)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.listKey)
        }
    }
}
