import Foundation
import CryptoKit
import Testing
import UIKit
@testable import Shum

@Suite("Local Bluetooth cards", .serialized)
@MainActor
struct LocalCardTests {
    private func makeStore() -> (LocalCardStore, URL, UserDefaults) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: "card-test-" + UUID().uuidString)!
        return (LocalCardStore(directory: url, defaults: defaults, secureStore: CardMemoryKeychain()), url, defaults)
    }
    private func photo(_ color: UIColor) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 500)).image { ctx in
            color.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 500))
        }
        return try LocalCardPhoto.prepare(image)
    }

    @Test func usernameValidationDoesNotClaimExternalOwnership() {
        #expect(LocalCardManifest.username(" @ruslan_11 ") == "ruslan_11")
        #expect(LocalCardManifest.username("https://example.org/ruslan_11") == nil)
        #expect(LocalCardManifest.username("ab") == nil)
        #expect(LocalCardManifest.username("имя123") == nil)
        #expect(LocalCardManifest.username("name/path") == nil)
    }

    @Test func seedOnlyAvatarDefaultsToPublicKeyAndPersistsWithoutAnImage() throws {
        let (store, url, defaults) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try store.saveOwn(name: "Аня", bio: nil, photo: nil)
        let initialSeed = try #require(first.body.avatarSeed)
        #expect(initialSeed == ShumPixelAvatarGenerator.seed(for: first.publicKey))
        #expect(first.body.photoHash == nil && first.body.photoBytes == 0)
        #expect(store.snapshot(first).photoUrl == nil)
        try first.validate()

        let model = ProfilePhotoViewModel(store: store)
        #expect(model.uiImage != nil)
        #expect(model.usePixelAvatar(seed: 42))
        let changed = try #require(store.ownManifest)
        #expect(changed.body.avatarSeed == 42)
        #expect(changed.body.photoBytes == 0 && changed.body.photoHash == nil)
        try changed.validate()

        let relaunched = LocalCardStore(directory: url, defaults: defaults,
            secureStore: CardMemoryKeychain())
        #expect(relaunched.ownManifest?.body.avatarSeed == 42)
        let jpegFiles = (try? FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "jpg" } ?? []
        #expect(jpegFiles.isEmpty)
    }

    @Test func registrationPreviewUsesThePreparedIdentitySeed() throws {
        let (store, url, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let publicKey = try store.prepareSigningKey()
        #expect(store.ownManifest == nil)
        let model = ProfilePhotoViewModel(store: store)
        try model.prepareRegistrationAvatar()
        let previewSeed = try #require(model.avatarSeed)
        #expect(model.uiImage != nil)
        #expect(previewSeed == ShumPixelAvatarGenerator.seed(for: publicKey))
        #expect(store.ownManifest == nil)
        #expect(try store.prepareSigningKey() == publicKey)

        // Returning to the ceremony must preserve a user's selected variant.
        #expect(model.usePixelAvatar(seed: previewSeed &+ 1))
        try model.prepareRegistrationAvatar()
        #expect(model.avatarSeed == previewSeed &+ 1)

        let saved = try store.saveOwn(name: "Аня", bio: nil, photo: nil,
            avatarSeed: model.avatarSeed)
        #expect(saved.publicKey == publicKey)
        #expect(saved.body.avatarSeed == previewSeed &+ 1)
    }

    @Test func registrationKeyPersistsInSystemKeychainBeforeProfileExists() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let keychain = KeychainStore(service: "Shum.registration-test." + UUID().uuidString)
        let defaultsName = "Shum.registration-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer {
            try? keychain.remove("shum.local-card.signing-key.v1")
            try? FileManager.default.removeItem(at: url)
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = LocalCardStore(directory: url, defaults: defaults, secureStore: keychain)
        let model = ProfilePhotoViewModel(store: store)
        try model.prepareRegistrationAvatar()
        let seed = try #require(model.avatarSeed)
        #expect(store.ownManifest == nil)

        let reopenedStore = LocalCardStore(directory: url, defaults: defaults, secureStore: keychain)
        let reopenedModel = ProfilePhotoViewModel(store: reopenedStore)
        try reopenedModel.prepareRegistrationAvatar()
        #expect(reopenedModel.avatarSeed == seed)
        let saved = try reopenedStore.saveOwn(name: "Аня", bio: nil, photo: nil)
        #expect(saved.body.avatarSeed == seed)
        #expect(saved.body.photoHash == nil)
    }

    @Test func identitySurvivesNameAndUsernameEdits() throws {
        let (store, url, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try store.saveOwn(name: "Руслан", username: "ruslan_11", bio: nil, photo: photo(.blue))
        let second = try store.saveOwn(name: "Ruslan", username: "new_username", bio: "Hello", photo: store.photo(first.body.photoHash))
        #expect(first.body.id == second.body.id)
        #expect(first.signature != second.signature)
        try second.validate()
        #expect(store.snapshot(second).photoUrl?.hasPrefix("file:") == true)
    }

    @Test func savedUsersPersistLocalPhotosByStableHash() throws {
        let hash = String(repeating: "a", count: 64)
        let oldURL = URL(
            fileURLWithPath: "/old-container/Library/Application Support/LocalCards-v1/\(hash).jpg"
        ).absoluteString
        let user = NearbyUser(
            id: UUID(),
            name: "Alina",
            username: "@alina_11",
            bio: nil,
            photoURL: oldURL
        )

        let encoded = try JSONEncoder().encode(user)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"photoHash\":\"\(hash)\""))
        #expect(!json.contains("old-container"))

        let restored = try JSONDecoder().decode(NearbyUser.self, from: encoded)
        #expect(restored == user)
        #expect(restored.photoURL == nil)
    }

    @Test func registrationSavesWithOnlyNameAndSurvivesRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = CardMemoryKeychain()
        let store = LocalCardStore(directory: root, secureStore: keys)
        let model = LocalProfileViewModel(store: store)
        #expect(model.save(name: "  Руслан  ", photo: nil))
        let own = try #require(store.ownManifest)
        #expect(own.body.name == "Руслан")
        #expect(own.body.version == 3 && own.body.username.isEmpty)
        #expect(own.body.avatarSeed == ShumPixelAvatarGenerator.seed(for: own.publicKey))
        try own.validate()
        #expect(model.saveError == nil)
        let restored = LocalCardStore(directory: root, secureStore: keys)
        #expect(restored.ownManifest == own)
        #expect(restored.snapshot(own).username == nil)
        #expect(!model.save(name: "  ", photo: nil))
        #expect(!model.save(name: "bad\nname", photo: nil))
        #expect(!model.save(name: String(repeating: "Я", count: 33), photo: nil))
        #expect(store.ownManifest == own)
    }

    @Test func editingLegacyProfileDropsUsernameAndPreservesIdentityAndPhoto() throws {
        let (store, url, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try store.saveOwn(name: "Руслан", username: "ruslan_11", bio: "Привет", photo: photo(.blue))
        let model = LocalProfileViewModel(store: store)
        #expect(model.updateName("Ruslan"))
        let updated = try #require(store.ownManifest)
        #expect(updated.body.name == "Ruslan")
        #expect(updated.body.username.isEmpty && updated.body.version == 2)
        #expect(updated.body.id == original.body.id)
        #expect(updated.body.bio == original.body.bio)
        #expect(updated.body.photoHash == original.body.photoHash)
        try updated.validate()
    }

    @Test func modifiedManifestIsRejected() throws {
        let (store, url, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try store.saveOwn(name: "Alina", username: "alina_11", bio: nil, photo: nil)
        let body = LocalCardBody(id: original.body.id, name: "Someone else", username: original.body.username, bio: nil, photoHash: nil, photoBytes: 0)
        let modified = LocalCardManifest(body: body, publicKey: original.publicKey, signature: original.signature)
        #expect(throws: (any Error).self) { try modified.validate() }
    }

    @Test func blocksStopProfileAcceptance() throws {
        let (a, aURL, defaults) = makeStore()
        let (b, bURL, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: aURL); try? FileManager.default.removeItem(at: bURL) }
        let bob = try b.saveOwn(name: "Bob", username: "bob_2026", bio: nil, photo: nil)
        defaults.set([bob.body.id.uuidString.lowercased()], forKey: "shum.blocked-profile-ids")
        #expect(throws: (any Error).self) { try a.receive(bob) }
    }

    @Test func explicitResetRemovesOwnAndReceivedCards() throws {
        let (store, url, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try store.saveOwn(name: "Alice", username: "alice_11", bio: nil, photo: photo(.blue))
        try store.reset()
        #expect(store.ownManifest == nil)
        #expect(store.photo(first.body.photoHash) == nil)
        let second = try store.saveOwn(name: "Alice", username: "alice_11", bio: nil, photo: nil)
        #expect(first.body.id != second.body.id)
    }


}

private final class CardMemoryKeychain: SecureStoring {
    private var values: [String: Data] = [:]
    func data(for key: String) throws -> Data? { values[key] }
    func set(_ data: Data, for key: String) throws { values[key] = data }
    func remove(_ key: String) throws { values.removeValue(forKey: key) }
}
