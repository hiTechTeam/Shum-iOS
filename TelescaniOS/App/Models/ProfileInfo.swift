import Foundation

struct ProfileInfo: Codable, Identifiable {
    let id: UUID
    let name: String?
    let username: String
    let bio: String?
    let photoURL: String?
    var cachedLocalPhotoPath: String?
}

struct NearbyUser: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let username: String
    let bio: String?
    let photoURL: String?

    var discoveryID: String {
        id.uuidString.lowercased()
    }
}

struct EncounterHistoryEntry: Identifiable, Codable, Equatable {
    let user: NearbyUser
    let lastSeen: Date

    var id: UUID {
        user.id
    }
}
