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
        /// The profile's ID on the network, which pushes are addressed to.
        var identityID: String? = nil
        /// Unread messages and unanswered invitations when it was left,
        /// plus pushes and fetches since; the open profile shows its live
        /// count instead.
        var unread: Int? = nil
        /// Invitations accepted by others since it was left.
        var accepted: Int? = nil
        /// What its badge in the list of profiles shows while it is closed.
        var waiting: Int { (unread ?? 0) + (accepted ?? 0) }
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

    /// Keeps the open profile's name, avatar and network ID for the list.
    func update(name: String, avatarSeed: UInt64?, identityID: String? = nil) {
        var entry = entries.first(where: { $0.id == active })
            ?? Entry(id: active, name: name, avatarSeed: avatarSeed)
        entry.name = name
        entry.avatarSeed = avatarSeed
        if let identityID { entry.identityID = identityID }
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

    /// Remembers a profile's unread count as it is left; `nil` once open,
    /// which also clears the accepted invitations it has now seen.
    func setUnread(_ count: Int?, profile id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let accepted = count == nil ? nil : entries[index].accepted
        guard entries[index].unread != count || entries[index].accepted != accepted else { return }
        entries[index].unread = count
        entries[index].accepted = accepted
        save()
    }

    /// A push with a message, an invitation or an accepted invitation for
    /// a profile that is not open counts one more there. Returns whether the
    /// push was for such a profile.
    @discardableResult
    func addUnread(identityID: String, kind: String) -> Bool {
        guard let index = entries.firstIndex(where: { $0.identityID == identityID }),
              entries[index].id != active else { return false }
        if kind == "invitation_accepted" {
            entries[index].accepted = (entries[index].accepted ?? 0) + 1
            save()
        } else if kind == "message" || kind == "invitation" {
            entries[index].unread = (entries[index].unread ?? 0) + 1
            save()
        }
        return true
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

/// Deletes one profile while others stay: its files, Keychain items and
/// settings. The first profile's files sit among the app's own, so only its
/// folders go; every other profile's folder goes as a whole.
@MainActor
enum ShumProfileEraser {
    static func erase(_ space: ShumProfileSpace) throws {
        let files = FileManager.default
        if space.id.isEmpty {
            for name in ["LocalCards-v1", "ShumProfiles", "ShumConversations"] {
                let folder = space.root.appendingPathComponent(name, isDirectory: true)
                if files.fileExists(atPath: folder.path) { try files.removeItem(at: folder) }
            }
        } else if files.fileExists(atPath: space.root.path) {
            try files.removeItem(at: space.root)
        }
        let keychain = KeychainManager.makeDefault()
        var identityKeys = ["noiseStaticKey", "ed25519SigningKey", ShumIdentityKeyNames.storage].map(space.key)
        if space.id.isEmpty { identityKeys.append(ShumIdentityKeyNames.legacyStorage) }
        for key in identityKeys { _ = keychain.deleteIdentityKey(forKey: key) }
        for key in ["nostr-current-identity", "nostr-device-seed"] {
            keychain.delete(key: space.key(key), service: "chat.shum.nostr")
        }
        try? KeychainStore.shared.remove(space.key("shum.local-card.signing-key.v1"))
        UserDefaults.standard.removeObject(forKey: space.key("shum.nickname"))
        if space.id.isEmpty { UserDefaults.standard.removeObject(forKey: "spotchat.nickname") }
    }
}
