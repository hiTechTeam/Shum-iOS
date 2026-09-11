import SwiftUI

@MainActor
final class LocalProfileViewModel: ObservableObject {
    @Published var telescanID: UUID?
    @Published var tgName: String?
    @Published var tgUsername: String?
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
        telescanID = profile.telescanId; tgName = profile.name
        tgUsername = profile.username.map { "@" + $0 }
        bio = profile.bio; localPhotoURL = profile.photoUrl; isUsernameConfirmed = true
    }
    @discardableResult func save(name: String, username: String, photo: Data?) -> Bool {
        do {
            try store.saveOwn(name: name, username: username, bio: bio, photo: photo)
            restoreLocalProfile(); saveError = nil; return true
        } catch {
            saveError = NSLocalizedString("local.profile.save.error", comment: "")
            return false
        }
    }
    @discardableResult func updateName(_ value: String) -> Bool {
        guard let own = store.ownManifest else { return false }
        return save(name: value, username: own.body.username, photo: store.photo(own.body.photoHash))
    }
    @discardableResult func updateUsername(_ value: String) -> Bool {
        guard let own = store.ownManifest else { return false }
        return save(name: own.body.name, username: value, photo: store.photo(own.body.photoHash))
    }
    func updateBio(_ value: String) async -> Bool {
        guard let own = store.ownManifest else { return false }
        isSavingBio = true
        defer { isSavingBio = false }
        do {
            try store.saveOwn(name: own.body.name, username: own.body.username,
                bio: value.trimmingCharacters(in: .whitespacesAndNewlines),
                photo: store.photo(own.body.photoHash))
            restoreLocalProfile(); bioSaveFailed = false; return true
        } catch { bioSaveFailed = true; return false }
    }
    func resetBioSaveState() { bioSaveFailed = false; bioContentRejected = false }
    func clearProfile() {
        telescanID = nil; tgName = nil; tgUsername = nil; bio = nil
        localPhotoURL = nil; isUsernameConfirmed = false; saveError = nil
    }
}
