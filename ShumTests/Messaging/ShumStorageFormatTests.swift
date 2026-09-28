import BitFoundation
import CryptoKit
import Foundation
import Testing
@preconcurrency @testable import Shum

/// Snapshots written by earlier builds must keep opening after refactoring.
@Suite("Shum stored conversation format", .serialized)
@MainActor
struct ShumStorageFormatTests {
    @MainActor final class Account {
        let wire = MockTransport()
        let identity: ShumIdentityService
        let card: ShumContactCard
        init(_ name: String) throws {
            identity = try ShumIdentityService(transport: wire, keychain: wire.mockKeychain, bridge: NostrIdentityBridge(keychain: wire.mockKeychain))
            card = try identity.card(name: name, bio: "Привет")
            wire.myPeerID = PeerID(publicKey: card.noiseKey)
        }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".enc")
    }

    /// Stores `contact` for `owner` and returns the database as it is persisted.
    private func database(of owner: Account, with contact: Account, at url: URL) throws -> ShumDatabase {
        let store = try ShumConversationStore(ownerID: owner.card.id, key: owner.identity.storageKey, url: url)
        let service = try ShumMessageStore(identity: owner.identity, store: store, transport: owner.wire, wire: owner.wire, card: owner.card, internet: nil)
        try service.add(contact.card, source: "test")
        return store.state
    }

    private func write(_ database: ShumDatabase, key: SymmetricKey, to url: URL) throws {
        try ChaChaPoly.seal(ShumCoding.encode(database), using: key).combined.write(to: url)
    }

    @Test func snapshotWithoutInvitationsKeepsSavedContactsMessageable() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = try Account("Аня"), contact = try Account("Борис")
        var legacy = try database(of: owner, with: contact, at: url)
        legacy.invitationStates = nil
        legacy.invitationOutbox = nil
        try write(legacy, key: owner.identity.storageKey, to: url)

        let restored = try ShumConversationStore(ownerID: owner.card.id, key: owner.identity.storageKey, url: url)
        #expect(restored.state.contacts.map(\.card) == [contact.card])
        let invitation = try #require(restored.state.invitationStates?[contact.card.id])
        #expect(invitation.phase == .accepted)
        #expect(invitation.eventID == "legacy-\(contact.card.id)")
        #expect(restored.state.invitationOutbox == [])

        // The migrated access survives the next write and reopening.
        try restored.transaction { _ in }
        let reopened = try ShumConversationStore(ownerID: owner.card.id, key: owner.identity.storageKey, url: url)
        #expect(reopened.state.invitationStates?[contact.card.id]?.phase == .accepted)
    }

    @Test func snapshotOfAnotherOwnerIsRejectedAndLeftIntact() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = try Account("Аня"), contact = try Account("Борис"), stranger = try Account("Вера")
        _ = try database(of: owner, with: contact, at: url)
        let bytes = try Data(contentsOf: url)

        #expect(throws: ShumFailure.unavailableIdentity) {
            _ = try ShumConversationStore(ownerID: stranger.card.id, key: owner.identity.storageKey, url: url)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func legacySavedProfilesAreDroppedWithoutLosingContacts() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = try Account("Аня"), contact = try Account("Борис")
        var legacy = try database(of: owner, with: contact, at: url)
        legacy.savedProfiles = [ShumSavedProfile(card: contact.card, savedAt: Date(), avatar: Data([1, 2, 3]))]
        try write(legacy, key: owner.identity.storageKey, to: url)

        let restored = try ShumConversationStore(ownerID: owner.card.id, key: owner.identity.storageKey, url: url)
        #expect(restored.state.savedProfiles == nil)
        #expect(restored.state.contacts.map(\.card) == [contact.card])
    }
}
