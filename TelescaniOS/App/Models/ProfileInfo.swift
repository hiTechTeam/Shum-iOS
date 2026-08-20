import Foundation

struct ProfileInfo: Codable, Identifiable {
    let id: UUID
    let name: String?
    let username: String
    let bio: String?
    let photoURL: String?
    var cachedLocalPhotoPath: String?
}

struct NearbyUser: Identifiable, Equatable {
    let id: UUID
    let name: String
    let username: String
    let bio: String?
    let photoURL: String?

    var discoveryID: String {
        id.uuidString.lowercased()
    }
}
