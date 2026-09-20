import Foundation
import XCTest
@preconcurrency @testable import Shum

/// Opt-in network smoke test. Only two freshly generated, test-owned identities
/// exchange a synthetic contact packet; no user contacts or message history.
@MainActor
final class ShumLiveRelayTests: XCTestCase {
    func testPrivateEnvelopeAcrossPublicRelays() async throws {
        guard ProcessInfo.processInfo.environment["SHUM_LIVE_NOSTR"] == "1" else { throw XCTSkip("Opt-in public relay smoke test") }
        let a = try NostrIdentity.generate(), b = try NostrIdentity.generate()
        let left = ShumNostrService(identity: a, manager: .shum())
        let right = ShumNostrService(identity: b, manager: .shum())
        defer { left.stop(); right.stop() }
        let cardA = ShumContactCard(noiseKey: Data(repeating: 1, count: 32), signingKey: Data(repeating: 2, count: 32), nostrKey: a.publicKeyHex, name: "Shum synthetic A", bio: "")
        let cardB = ShumContactCard(noiseKey: Data(repeating: 3, count: 32), signingKey: Data(repeating: 4, count: 32), nostrKey: b.publicKeyHex, name: "Shum synthetic B", bio: "")
        var receivedA = false, receivedB = false, accepted = false
        left.received = { packet, sender in receivedA = packet.card == cardB && sender == b.publicKeyHex }
        right.received = { packet, sender in receivedB = packet.card == cardA && sender == a.publicKeyHex }
        left.start(); right.start()
        let connectDeadline = Date().addingTimeInterval(30)
        while !(left.connected && right.connected), Date() < connectDeadline { try await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertTrue(left.connected && right.connected, "No relay connection")
        guard left.connected && right.connected else { return }
        // Connections to the independent relays become ready at different
        // times. Exercise the same bounded retry behavior as the durable outbox.
        let receiveDeadline = Date().addingTimeInterval(60)
        var nextAttempt = Date.distantPast
        while !(receivedB && accepted), Date() < receiveDeadline {
            if Date() >= nextAttempt {
                nextAttempt = Date().addingTimeInterval(10)
                left.send(ShumPacket(card: cardA), to: cardB) { accepted = accepted || $0 }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(accepted, "Relay did not acknowledge publication")
        XCTAssertTrue(receivedB, "Recipient did not decrypt publication")
        right.send(ShumPacket(card: cardB), to: cardA) { _ in }
        let replyDeadline = Date().addingTimeInterval(30)
        while !receivedA, Date() < replyDeadline { try await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertTrue(receivedA, "Reply was not decrypted")
    }
}
