import SwiftUI

@MainActor
final class ProfilePhotoViewModel: ObservableObject {
    @Published var profileImage: Image = .noPhoto
    @Published var uiImage: UIImage?
    @Published var saveFailed = false
    private(set) var avatarSeed: UInt64?
    private let store: LocalCardStore

    init(store: LocalCardStore = .shared) {
        self.store = store
        loadPhotoIfNeeded()
    }

    func resetAccountScopedState() {
        avatarSeed = nil
        uiImage = nil
        profileImage = .noPhoto
    }

    func loadPhotoIfNeeded() {
        guard let own = store.ownManifest else { return }
        let seed = own.body.avatarSeed
            ?? ShumPixelAvatarGenerator.seed(for: own.publicKey)
        avatarSeed = seed
        let image = ShumPixelAvatarGenerator.image(seed: seed)
        uiImage = image
        profileImage = Image(uiImage: image)
    }

    func loadPhotoFromURL(_ value: String?) {
        guard store.ownManifest != nil else { return }
        loadPhotoIfNeeded()
    }

    func prepareRegistrationAvatar(seed: UInt64) {
        guard store.ownManifest == nil, avatarSeed == nil else { return }
        avatarSeed = seed
        let image = ShumPixelAvatarGenerator.image(seed: seed)
        uiImage = image
        profileImage = Image(uiImage: image)
    }

    @discardableResult
    func usePixelAvatar(seed: UInt64) -> Bool {
        do {
            if let own = store.ownManifest {
                try store.saveOwn(name: own.body.name, bio: own.body.bio,
                    photo: nil, avatarSeed: seed, preservePhotoEditing: false)
            }
            avatarSeed = seed
            let image = ShumPixelAvatarGenerator.image(seed: seed)
            uiImage = image
            profileImage = Image(uiImage: image)
            saveFailed = false
            NotificationCenter.default.post(name: .localCardChanged, object: nil)
            return true
        } catch {
            saveFailed = true
            return false
        }
    }
}

extension Notification.Name {
    static let localCardChanged = Notification.Name("shum.local-card.changed")
}
