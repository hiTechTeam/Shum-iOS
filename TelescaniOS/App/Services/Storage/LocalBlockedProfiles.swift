import Foundation

enum LocalBlockedProfiles {
    private static let key = "telescan.local-blocked-profiles.v1"
    static func load() -> [BlockedProfileResponse] {
        let data = UserDefaults.standard.data(forKey: key)
        var profiles = data.flatMap { try? JSONDecoder().decode([BlockedProfileResponse].self, from: $0) } ?? []
        let known = Set(profiles.map { $0.id.uuidString.lowercased() })
        // Keep pre-migration blocks even if the old API never cached their details.
        for value in UserDefaults.standard.stringArray(forKey: "telescan.blocked-profile-ids") ?? [] {
            if !known.contains(value.lowercased()), let id = UUID(uuidString: value) {
                profiles.append(BlockedProfileResponse(telescanId: id, name: nil,
                    username: nil, photoUrl: nil, blockedAt: ""))
            }
        }
        return profiles
    }
    static func save(_ values: [BlockedProfileResponse]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(values), forKey: key)
    }
}
