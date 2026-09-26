import BitFoundation
import CryptoKit
import Foundation
import Testing
@preconcurrency @testable import Shum

/// The once-a-minute cleanup rewrites the whole encrypted store, so it must
/// only run when an entry has actually expired.
@Suite("Shum store cleanup", .serialized)
@MainActor
struct ShumStoreCleanupTests {
    final class Clock { var date = Date() }

    @Test func periodicCleanupWritesOnlyWhenSomethingExpired() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".enc")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock(), wire = MockTransport()
        let identity = try ShumIdentityService(transport: wire, keychain: wire.mockKeychain, bridge: NostrIdentityBridge(keychain: wire.mockKeychain))
        let card = try identity.card(name: "Аня", bio: "Привет")
        wire.myPeerID = PeerID(publicKey: card.noiseKey)
        let store = try ShumConversationStore(ownerID: card.id, key: identity.storageKey, url: url)
        let service = ShumMessageStore(identity: identity, store: store, transport: wire, wire: wire, card: card, internet: nil, now: { clock.date })
        try store.transaction { state in
            state.seenRelay["relay-copy"] = clock.date.addingTimeInterval(3_600)
            state.deletedMessageIDs = ["deleted-message": clock.date.addingTimeInterval(3_600)]
        }
        let untouched = try Data(contentsOf: url)

        for _ in 0..<30 { service.tick(connected: [], active: false) }
        #expect(try Data(contentsOf: url) == untouched, "Nothing expired, so the store is not rewritten")
        #expect(store.state.seenRelay.count == 1)

        clock.date.addTimeInterval(7_200)
        for _ in 0..<30 { service.tick(connected: [], active: false) }
        #expect(try Data(contentsOf: url) != untouched, "Expired entries are removed and saved")
        #expect(store.state.seenRelay.isEmpty)
        #expect(store.state.deletedMessageIDs?.isEmpty == true)

        let reopened = try ShumConversationStore(ownerID: card.id, key: identity.storageKey, url: url)
        #expect(reopened.state.seenRelay.isEmpty)
    }
}
