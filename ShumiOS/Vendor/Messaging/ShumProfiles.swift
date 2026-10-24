import Combine
import CryptoKit
import Foundation
import ImageIO

struct ShumProfile: Codable, Equatable {
    var name: String
    var bio: String = ""
    var avatar: Data?
    var avatarSeed: UInt64?
    static let maxBioCharacters = 72
    static let maxAvatarBytes = 40 * 1024

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validAvatar(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxAvatarBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 360, height <= 360 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
    var valid: Bool {
        InputValidator.validateNickname(name) == name && name.utf8.count <= 64 && bio.count <= Self.maxBioCharacters && bio.utf8.count <= 640 &&
        !bio.unicodeScalars.contains { CharacterSet.controlCharacters.subtracting(.newlines).contains($0) } &&
        (avatar.map(Self.validAvatar) ?? true)
    }

    @MainActor
    func rendered() -> ShumProfile {
        guard let avatarSeed else { return self }
        var result = self
        result.avatar = ShumPixelAvatarGenerator.data(seed: avatarSeed)
        return result
    }
}

/// The own profile is kept on disk; avatar pixels are made locally from the seed.
final class ShumProfileStore {
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    static func live() -> ShumProfileStore {
        ShumProfileStore(directory: ShumProfileSpace.active.root.appendingPathComponent("ShumProfiles", isDirectory: true))
    }
    func loadOwn() -> ShumProfile? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("own.json")),
              data.count <= 60 * 1024, var profile = try? JSONDecoder().decode(ShumProfile.self, from: data) else { return nil }
        profile.bio = String(profile.bio.prefix(ShumProfile.maxBioCharacters))
        guard profile.valid else { return nil }
        return profile
    }
    func saveOwn(_ profile: ShumProfile) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var stored = profile
        stored.avatar = nil
        try JSONEncoder().encode(stored).write(to: directory.appendingPathComponent("own.json"), options: .atomic)
    }
}

/// The person's own profile as screens show and edit it. Other people's
/// profiles come from their signed cards in Shum-Core.
@MainActor
final class ShumProfiles: ObservableObject {
    @Published private(set) var own: ShumProfile
    private let store: ShumProfileStore
    private var retired = false

    init(name: String, store: ShumProfileStore = ShumProfileStore()) {
        self.store = store
        own = (store.loadOwn() ?? ShumProfile(name: name)).rendered()
    }
    func retire() {
        retired = true
        own = ShumProfile(name: "")
    }
    func save(_ profile: ShumProfile) throws {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        guard profile.valid else { throw CocoaError(.validationMissingMandatoryProperty) }
        let displayed = profile.rendered()
        try store.saveOwn(displayed)
        own = displayed
    }
}
