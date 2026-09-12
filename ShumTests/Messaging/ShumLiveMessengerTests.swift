import BitFoundation
import Foundation
import XCTest
@preconcurrency @testable import Shum

/// Opt-in integration against public relays with fresh, test-owned keys only.
/// Bluetooth is disconnected. A recipient must decrypt, store and sign a read
/// receipt before this test considers the message delivered.
@MainActor
final class ShumLiveMessengerTests: XCTestCase {
    @MainActor final class Node {
        let wire = MockTransport()
        let identity: SpotchatIdentityService
        let card: SpotchatContactCard
        let internet: SpotchatNostrService
        let service: SpotchatMessageStore
        init(_ name: String) throws {
            identity = try SpotchatIdentityService(transport: wire, keychain: wire.mockKeychain, bridge: NostrIdentityBridge(keychain: wire.mockKeychain))
            card = try identity.card(name: name, bio: "")
            internet = SpotchatNostrService(identity: identity.nostr, manager: .spotchat())
            let store = try SpotchatConversationStore(ownerID: card.id, key: identity.storageKey, url: nil)
            service = SpotchatMessageStore(identity: identity, store: store, transport: wire, wire: wire, card: card, internet: internet)
        }
    }
    func testEncryptedConversationAndReadReceiptWithoutBluetooth() async throws {
        guard ProcessInfo.processInfo.environment["SHUM_LIVE_NOSTR"] == "1" else { throw XCTSkip("Opt-in live relay test") }
        let alice = try Node("Shum synthetic A"), bob = try Node("Shum synthetic B")
        defer { alice.service.retire(); bob.service.retire() }
        try alice.service.add(bob.card, source: "test")
        try bob.service.add(alice.card, source: "test")
        alice.service.start(); bob.service.start()
        let connectDeadline = Date().addingTimeInterval(30)
        while !(alice.internet.connected && bob.internet.connected), Date() < connectDeadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(alice.internet.connected && bob.internet.connected, "Both Nostr clients must connect")
        guard alice.internet.connected && bob.internet.connected else { return }
        bob.service.open(alice.card)
        let text = "Shum encrypted integration " + UUID().uuidString
        XCTAssertTrue(alice.service.send(text, to: bob.card))
        let deadline = Date().addingTimeInterval(90)
        while alice.service.state.messages.first?.status != .read, Date() < deadline {
            alice.service.tick(connected: [], active: true)
            bob.service.tick(connected: [], active: true)
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        XCTAssertEqual(bob.service.state.messages.first?.text, text)
        XCTAssertEqual(bob.service.state.messages.count, 1)
        XCTAssertEqual(alice.service.state.messages.first?.status, .read)
        XCTAssertTrue(alice.wire.spotchatPackets.isEmpty && bob.wire.spotchatPackets.isEmpty, "No BLE shortcut")
    }
}
