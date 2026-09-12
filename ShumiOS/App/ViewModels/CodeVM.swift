import SwiftUI

@MainActor
final class LocalProfileViewModel: ObservableObject {
    @Published var shumID: UUID?
    @Published var localName: String?
    @Published var localUsername: String?
    @Published var bio: String?
    @Published var localPhotoURL: String?
    @Published var isUsernameConfirmed = false
    @Published var isSavingBio = false
    @Published var bioSaveFailed = false
    @Published var bioContentRejected = false
    @Published var saveError: String?
    private let store: LocalCardStore
    init(store: LocalCardStore = .shared) { self.store = store; restoreLocalProfile() }
    func restoreLocalProfile() {
        guard let own = store.ownManifest else { return }
        let profile = store.snapshot(own)
        shumID = profile.shumId; localName = profile.name
        localUsername = profile.username.map { "@" + $0 }
        bio = profile.bio; localPhotoURL = profile.photoUrl; isUsernameConfirmed = true
    }
    @discardableResult func save(name: String, username: String? = nil, photo: Data?) -> Bool {
        guard let name = ShumProfileValidation.name(name) else {
            saveError = "Введите короткое имя без служебных символов."; return false
        }
        do {
            try store.saveOwn(name: name, bio: bio, photo: photo)
            restoreLocalProfile(); saveError = nil; return true
        } catch {
            saveError = NSLocalizedString("local.profile.save.error", comment: "")
            return false
        }
    }
    @discardableResult func updateName(_ value: String) -> Bool {
        guard let own = store.ownManifest else { return false }
        return save(name: value, photo: store.photo(own.body.photoHash))
    }
    func updateBio(_ value: String) async -> Bool {
        guard let own = store.ownManifest else { return false }
        isSavingBio = true
        defer { isSavingBio = false }
        do {
            try store.saveOwn(name: own.body.name,
                bio: value.trimmingCharacters(in: .whitespacesAndNewlines),
                photo: store.photo(own.body.photoHash))
            restoreLocalProfile(); bioSaveFailed = false; return true
        } catch { bioSaveFailed = true; return false }
    }
    func resetBioSaveState() { bioSaveFailed = false; bioContentRejected = false }
    func clearProfile() {
        shumID = nil; localName = nil; localUsername = nil; bio = nil
        localPhotoURL = nil; isUsernameConfirmed = false; saveError = nil
    }
}
