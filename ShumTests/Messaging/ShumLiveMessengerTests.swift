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
        let identity: ShumIdentityService
        let card: ShumContactCard
        let manager: NostrRelayManager
        let internet: ShumNostrService
        let service: ShumMessageStore
        init(_ name: String) throws {
            identity = try ShumIdentityService(transport: wire, keychain: wire.mockKeychain, bridge: NostrIdentityBridge(keychain: wire.mockKeychain))
            card = try identity.card(name: name, bio: "")
            wire.myPeerID = PeerID(publicKey: card.noiseKey)
            manager = .shum()
            internet = ShumNostrService(identity: identity.nostr, manager: manager)
            let store = try ShumConversationStore(ownerID: card.id, key: identity.storageKey, url: nil)
            service = ShumMessageStore(identity: identity, store: store, transport: wire, wire: wire, card: card, internet: internet)
        }
    }
    func testEncryptedConversationAndReadReceiptWithoutBluetooth() async throws {
        guard ProcessInfo.processInfo.environment["SHUM_LIVE_NOSTR"] == "1" else {
            throw XCTSkip("Opt-in live relay test")
        }
        let alice = try Node("Shum synthetic A"), bob = try Node("Shum synthetic B")
        defer { alice.service.retire(); bob.service.retire() }
        alice.service.start(); bob.service.start()
        let connectDeadline = Date().addingTimeInterval(30)
        while !(alice.internet.connected && bob.internet.connected), Date() < connectDeadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let relayStatus = "Alice: \(alice.manager.relays.map { "\($0.url)=\($0.isConnected):\($0.lastError?.localizedDescription ?? "none")" }); Bob: \(bob.manager.relays.map { "\($0.url)=\($0.isConnected):\($0.lastError?.localizedDescription ?? "none")" })"
        XCTAssertTrue(alice.internet.connected && bob.internet.connected, "Both Nostr clients must connect. \(relayStatus)")
        guard alice.internet.connected && bob.internet.connected else { return }
        XCTAssertTrue(alice.service.sendInvitation(bob.card))
        let invitationDeadline = Date().addingTimeInterval(30)
        while bob.service.invitationPhase(for: alice.card) != .incomingPending,
              Date() < invitationDeadline {
            alice.service.tick(connected: [], active: true)
            bob.service.tick(connected: [], active: true)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(bob.service.invitationPhase(for: alice.card), .incomingPending)
        guard bob.service.invitationPhase(for: alice.card) == .incomingPending else { return }
        XCTAssertTrue(bob.service.acceptInvitation(alice.card))
        let acceptanceDeadline = Date().addingTimeInterval(30)
        while alice.service.invitationPhase(for: bob.card) != .accepted,
              Date() < acceptanceDeadline {
            alice.service.tick(connected: [], active: true)
            bob.service.tick(connected: [], active: true)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(alice.service.invitationPhase(for: bob.card), .accepted)
        guard alice.service.invitationPhase(for: bob.card) == .accepted else { return }
        // The sender still thinks Bluetooth is connected, while the receiver
        // no longer reads any BLE packets. Internet must run in parallel.
        alice.wire.connectedPeers = [bob.wire.myPeerID]
        alice.wire.shumSessionKeys[bob.wire.myPeerID] = bob.card.noiseKey
        alice.service.receive(
            ShumPacket(card: bob.card), from: bob.wire.myPeerID, nostrSender: nil
        )
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
        XCTAssertFalse(alice.wire.shumPackets.isEmpty, "The stale BLE route was exercised")
        XCTAssertTrue(bob.wire.shumPackets.isEmpty, "The receiver has no BLE route")

        alice.internet.stop()
        let afterReconnect = "Shum reconnect integration " + UUID().uuidString
        XCTAssertTrue(alice.service.send(afterReconnect, to: bob.card))
        alice.internet.start()
        let reconnectDeadline = Date().addingTimeInterval(20)
        while !alice.internet.connected, Date() < reconnectDeadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(alice.internet.connected)
        let pendingDeadline = Date().addingTimeInterval(10)
        while !bob.service.state.messages.contains(where: { $0.text == afterReconnect }),
              Date() < pendingDeadline {
            alice.service.tick(connected: [], active: true)
            bob.service.tick(connected: [], active: true)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(bob.service.state.messages.contains(where: { $0.text == afterReconnect }))

        alice.service.open(bob.card)
        let reply = "Shum reverse integration " + UUID().uuidString
        XCTAssertTrue(bob.service.send(reply, to: alice.card))
        let replyDeadline = Date().addingTimeInterval(30)
        while bob.service.state.messages.first(where: { $0.outgoing })?.status != .read,
              Date() < replyDeadline {
            alice.service.tick(connected: [], active: true)
            bob.service.tick(connected: [], active: true)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertEqual(alice.service.state.messages.first(where: { !$0.outgoing })?.text, reply)
        XCTAssertEqual(bob.service.state.messages.first(where: { $0.outgoing })?.status, .read)
    }
}
