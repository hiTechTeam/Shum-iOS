import Foundation

struct ProfileInfo: Codable, Identifiable {
    let id: UUID
    let name: String?
    let username: String
    let photoURL: String?
    var cachedLocalPhotoPath: String?
}

struct NearbyUser: Identifiable {
    let id: UUID
    let name: String?
    let username: String?
    let photoURL: String?
}
