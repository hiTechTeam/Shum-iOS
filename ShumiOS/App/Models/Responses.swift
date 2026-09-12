import Foundation

struct ShumProfileResponse: Codable, Equatable {
    let shumId: UUID
    let name: String?
    let username: String?
    let bio: String?
    let photoUrl: String?
    let messengerLinked: Bool?

    var isMessengerLinked: Bool {
        if let messengerLinked { return messengerLinked }
        return !(username?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ?? true)
    }

    init(
        shumId: UUID,
        name: String?,
        username: String?,
        bio: String? = nil,
        photoUrl: String?,
        messengerLinked: Bool? = nil
    ) {
        self.shumId = shumId
        self.name = name
        self.username = username
        self.bio = bio
        self.photoUrl = photoUrl
        self.messengerLinked = messengerLinked
    }
}

struct BlockedProfileResponse: Codable, Equatable, Identifiable {
    let shumId: UUID
    let name: String?
    let username: String?
    let photoUrl: String?
    let blockedAt: String

    var id: UUID { shumId }
}
