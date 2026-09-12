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
        #expect(own.body.version == 2 && own.body.username.isEmpty)
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

    @Test(arguments: [20, 185, 512])
    func twoWayExchangeAndPersistentPhotos(mtu: Int) throws {
        let (a, aURL, aDefaults) = makeStore()
        let (b, bURL, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: aURL); try? FileManager.default.removeItem(at: bURL) }
        let alice = try a.saveOwn(name: "Алина", username: "alina_11", bio: "Привет", photo: photo(.orange))
        let bob = try b.saveOwn(name: "Bob", username: "bob_2026", bio: nil, photo: photo(.blue))
        var updatesA = 0
        var updatesB = 0
        let left = try BLECardExchange(own: alice, expectedPeer: bob.body.id, store: a) { _ in updatesA += 1 }
        let right = try BLECardExchange(own: bob, expectedPeer: alice.body.id, store: b) { _ in updatesB += 1 }
        for _ in 0..<20000 {
            if let frame = left.nextFrame(maximumBytes: mtu) { #expect(frame.count <= mtu); try right.receive(frame) }
            if let frame = right.nextFrame(maximumBytes: mtu) { #expect(frame.count <= mtu); try left.receive(frame) }
            if left.complete && right.complete { break }
        }
        #expect(left.complete && right.complete)
        #expect(updatesA == 2 && updatesB == 2)
        #expect(a.photo(bob.body.photoHash) == b.photo(bob.body.photoHash))
        let relaunched = LocalCardStore(directory: aURL, defaults: aDefaults, secureStore: CardMemoryKeychain())
        #expect(try relaunched.profile(bob.body.id).name == "Bob")
        #expect(relaunched.photo(bob.body.photoHash) != nil)
        // A repeat encounter reuses both photos and sends metadata only.
        let repeatLeft = try BLECardExchange(own: alice, expectedPeer: bob.body.id, store: a) { _ in }
        let repeatRight = try BLECardExchange(own: bob, expectedPeer: alice.body.id, store: b) { _ in }
        var bytes = 0
        for _ in 0..<2000 {
            if let frame = repeatLeft.nextFrame(maximumBytes: mtu) { bytes += frame.count; try repeatRight.receive(frame) }
            if let frame = repeatRight.nextFrame(maximumBytes: mtu) { bytes += frame.count; try repeatLeft.receive(frame) }
            if repeatLeft.complete && repeatRight.complete { break }
        }
        #expect(repeatLeft.complete && repeatRight.complete)
        #expect(bytes < 4000)
    }

    @Test func blocksStopProfileAcceptance() throws {
        let (a, aURL, defaults) = makeStore()
        let (b, bURL, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: aURL); try? FileManager.default.removeItem(at: bURL) }
        let bob = try b.saveOwn(name: "Bob", username: "bob_2026", bio: nil, photo: nil)
        defaults.set([bob.body.id.uuidString.lowercased()], forKey: "shum.blocked-profile-ids")
        #expect(throws: (any Error).self) { try a.receive(bob) }
    }

    @Test func corruptFramesAndPhotoPayloadsAreRejected() throws {
        let (store, url, _) = makeStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let own = try store.saveOwn(name: "Alice", username: "alice_11", bio: nil, photo: nil)
        let exchange = try BLECardExchange(own: own, expectedPeer: nil, store: store) { _ in }
        #expect(throws: (any Error).self) { try exchange.receive(Data([1, 2, 3])) }
        #expect(throws: (any Error).self) { try exchange.receive(Data([2, 0, 0, 0, 1, 255, 255, 0, 0, 1])) }
        let invalid = Data(repeating: 255, count: 100)
        #expect(throws: (any Error).self) { try store.cachePhoto(invalid, hash: LocalCardPhoto.hash(invalid)) }
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
