import SwiftUI

@MainActor
final class ProfilePhotoViewModel: ObservableObject {
    @Published var profileImage: Image = .noPhoto
    @Published var uiImage: UIImage?
    @Published var saveFailed = false
    @Published private(set) var isNoisyPhoto = false
    private(set) var preparedPhoto: Data?
    private(set) var photoEditing: LocalPhotoEditingState?
    private var originalPhoto: Data?
    private let store: LocalCardStore
    private let usesLegacyCache: Bool

    init(store: LocalCardStore = .shared, usesLegacyCache: Bool = true) {
        self.store = store
        self.usesLegacyCache = usesLegacyCache
        loadPhotoIfNeeded()
    }

    func resetAccountScopedState() {
        uiImage = nil; preparedPhoto = nil; profileImage = .noPhoto
        originalPhoto = nil; photoEditing = nil; isNoisyPhoto = false
        if usesLegacyCache { ProfileImageStorage.delete() }
    }

    func loadPhotoIfNeeded() {
        if let own = store.ownManifest {
            preparedPhoto = store.photo(own.body.photoHash)
            photoEditing = store.ownPhotoEditing
            originalPhoto = photoEditing?.original ?? preparedPhoto
            isNoisyPhoto = photoEditing != nil
        } else if usesLegacyCache, let image = ProfileImageStorage.load() {
            preparedPhoto = try? LocalCardPhoto.prepare(image)
            originalPhoto = preparedPhoto
        }
        uiImage = preparedPhoto.flatMap { UIImage(data: $0) }
        profileImage = uiImage.map { Image(uiImage: $0) } ?? .noPhoto
    }

    func loadPhotoFromURL(_ value: String?) {
        guard store.ownManifest != nil else { return }
        loadPhotoIfNeeded()
    }

    func updateProfileImage(with image: UIImage?) {
        do {
            let original = try image.map { try LocalCardPhoto.prepare($0) }
            try save(original: original, noisy: original != nil && isNoisyPhoto)
        } catch { saveFailed = true }
    }

    func setNoisyPhoto(_ enabled: Bool) {
        guard enabled != isNoisyPhoto, let originalPhoto else { return }
        do { try save(original: originalPhoto, noisy: enabled) }
        catch { saveFailed = true }
    }

    private func save(original: Data?, noisy: Bool) throws {
        let data = try original.map { noisy ? try LocalCardPhoto.noisy($0) : $0 }
        let editing = noisy ? data.flatMap { data in
            original.map { LocalPhotoEditingState(original: $0, noisyPhotoHash: LocalCardPhoto.hash(data)) }
        } : nil
        if let own = store.ownManifest {
            try store.saveOwn(name: own.body.name, bio: own.body.bio, photo: data, photoEditing: editing, preservePhotoEditing: false)
        }
        originalPhoto = original
        photoEditing = editing
        isNoisyPhoto = noisy
        preparedPhoto = data
        uiImage = data.flatMap { UIImage(data: $0) }
        profileImage = uiImage.map { Image(uiImage: $0) } ?? .noPhoto
        if usesLegacyCache {
            if let uiImage { ProfileImageStorage.save(uiImage) } else { ProfileImageStorage.delete() }
        }
        saveFailed = false
        NotificationCenter.default.post(name: .localCardChanged, object: nil)
    }
}

extension Notification.Name {
    static let localCardChanged = Notification.Name("shum.local-card.changed")
}
