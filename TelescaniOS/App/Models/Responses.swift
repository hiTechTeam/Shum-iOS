import Foundation

struct TelescanProfileResponse: Codable, Equatable {
    let telescanId: UUID
    let name: String?
    let username: String?
    let bio: String?
    let photoUrl: String?
    let telegramLinked: Bool?

    var isTelegramLinked: Bool {
        if let telegramLinked { return telegramLinked }
        return !(username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ?? true)
    }

    init(
        telescanId: UUID,
        name: String?,
        username: String?,
        bio: String? = nil,
        photoUrl: String?,
        telegramLinked: Bool? = nil
    ) {
        self.telescanId = telescanId
        self.name = name
        self.username = username
        self.bio = bio
        self.photoUrl = photoUrl
        self.telegramLinked = telegramLinked
    }
}

struct BlockedProfileResponse: Codable, Equatable, Identifiable {
    let telescanId: UUID
    let name: String?
    let username: String?
    let photoUrl: String?
    let blockedAt: String

    var id: UUID { telescanId }
}
