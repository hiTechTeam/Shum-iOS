import Foundation

enum EncounterHistoryPolicy {
    static let retention: TimeInterval = 24 * 60 * 60
}

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
    private let storedPhotoURL: String?
    private let photoHash: String?

    /// Resolves a content-addressed photo against the app's current container.
    /// Absolute sandbox paths are not durable when iOS relocates the app container.
    var photoURL: String? {
        if let photoHash,
           let currentURL = LocalCardStore.shared.photoURL(photoHash) {
            return currentURL.absoluteString
        }
        guard let storedPhotoURL else { return nil }
        guard let url = URL(string: storedPhotoURL), url.isFileURL else {
            return storedPhotoURL
        }
        return FileManager.default.fileExists(atPath: url.path)
            ? storedPhotoURL
            : nil
    }

    init(
        id: UUID,
        name: String,
        username: String,
        bio: String?,
        photoURL: String?
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.bio = bio
        storedPhotoURL = photoURL
        photoHash = Self.localPhotoHash(from: photoURL)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, username, bio, photoURL, photoHash
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        username = try container.decode(String.self, forKey: .username)
        bio = try container.decodeIfPresent(String.self, forKey: .bio)
        let legacyURL = try container.decodeIfPresent(
            String.self,
            forKey: .photoURL
        )
        let encodedHash = try container.decodeIfPresent(
            String.self,
            forKey: .photoHash
        )
        photoHash = Self.validatedPhotoHash(encodedHash)
            ?? Self.localPhotoHash(from: legacyURL)
        storedPhotoURL = legacyURL
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(bio, forKey: .bio)
        if let photoHash {
            try container.encode(photoHash, forKey: .photoHash)
        } else {
            try container.encodeIfPresent(storedPhotoURL, forKey: .photoURL)
        }
    }

    static func == (lhs: NearbyUser, rhs: NearbyUser) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.username == rhs.username
            && lhs.bio == rhs.bio
            && lhs.photoHash == rhs.photoHash
            && (lhs.photoHash != nil
                || lhs.storedPhotoURL == rhs.storedPhotoURL)
    }

    private static func validatedPhotoHash(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.lowercased()
        return LocalCardPhoto.validHash(normalized) ? normalized : nil
    }

    private static func localPhotoHash(from value: String?) -> String? {
        guard let value,
              let url = URL(string: value),
              url.isFileURL else { return nil }
        return validatedPhotoHash(
            url.deletingPathExtension().lastPathComponent
        )
    }

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
