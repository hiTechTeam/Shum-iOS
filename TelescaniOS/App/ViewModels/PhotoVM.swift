import SwiftUI

@MainActor
final class ProfilePhotoViewModel: ObservableObject {
    @Published var profileImage: Image = .noPhoto
    @Published var uiImage: UIImage?
    @Published var saveFailed = false
    private(set) var preparedPhoto: Data?
    init() { loadPhotoIfNeeded() }
    func resetAccountScopedState() {
        uiImage = nil; preparedPhoto = nil; profileImage = .noPhoto
        ProfileImageStorage.delete()
    }
    func loadPhotoIfNeeded() {
        if let own = LocalCardStore.shared.ownManifest {
            preparedPhoto = LocalCardStore.shared.photo(own.body.photoHash)
            uiImage = preparedPhoto.flatMap { UIImage(data: $0) }
        } else if let image = ProfileImageStorage.load() {
            preparedPhoto = try? LocalCardPhoto.prepare(image)
            uiImage = preparedPhoto.flatMap { UIImage(data: $0) }
        }
        profileImage = uiImage.map { Image(uiImage: $0) } ?? .noPhoto
    }
    func loadPhotoFromURL(_ value: String?) {
        guard LocalCardStore.shared.ownManifest != nil else { return }
        loadPhotoIfNeeded()
    }
    func updateProfileImage(with image: UIImage?) {
        do {
            let data = try image.map { try LocalCardPhoto.prepare($0) }
            if let own = LocalCardStore.shared.ownManifest {
                try LocalCardStore.shared.saveOwn(name: own.body.name, username: own.body.username, bio: own.body.bio, photo: data)
            }
            preparedPhoto = data; uiImage = data.flatMap { UIImage(data: $0) }
            profileImage = uiImage.map { Image(uiImage: $0) } ?? .noPhoto
            if let uiImage { ProfileImageStorage.save(uiImage) } else { ProfileImageStorage.delete() }
            saveFailed = false
            NotificationCenter.default.post(name: .localCardChanged, object: nil)
        } catch { saveFailed = true }
    }
}
extension Notification.Name {
    static let localCardChanged = Notification.Name("telescan.local-card.changed")
}
