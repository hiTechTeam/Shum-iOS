import BitFoundation
import CryptoKit
import Foundation
import Testing
@preconcurrency @testable import Shum

/// Opt-in measurement of the single-file conversation store. Run with
/// `TEST_RUNNER_SHUM_STORE_BENCH=1 xcodebuild test ...`. Debug builds encode
/// JSON more slowly than release builds, so the timings are an upper bound.
@Suite("Shum conversation store benchmark", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["SHUM_STORE_BENCH"] == "1"))
@MainActor
struct ShumStoreBenchmarkTests {
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

    private func milliseconds(_ repeats: Int, _ work: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        var total = Duration.zero
        for _ in 0..<repeats { total += try clock.measure(work) }
        let parts = (total / repeats).components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }

    @Test(arguments: [1_000, 5_000, 10_000, 25_000, 50_000])
    func writeAndOpenCost(messageCount: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".enc")
        defer { try? FileManager.default.removeItem(at: url) }
        let owner = try Account("Аня"), contact = try Account("Борис")
        let store = try ShumConversationStore(ownerID: owner.card.id, key: owner.identity.storageKey, url: url)
        let service = try ShumMessageStore(identity: owner.identity, store: store, transport: owner.wire, wire: owner.wire, card: owner.card, internet: nil)
        try service.add(contact.card, source: "benchmark")
        try store.transaction { state in
            state.invitationStates?[contact.card.id] = ShumInvitationState(phase: .accepted, updatedAt: 0, eventID: "benchmark")
        }
        let text = "Привет! Встречаемся у входа в шесть, я буду в синей куртке. Напиши, как подойдёшь 🙂"
        #expect(service.send(text, to: contact.card))
        let template = try #require(store.state.messages.first)

        do {
            try store.transaction { state in
                state.messages = (0..<messageCount).map { index in
                    var message = template
                    message.envelope.id = "benchmark-\(index)"
                    message.outgoing = index.isMultiple(of: 2)
                    return message
                }
            }
        } catch {
            print("SHUM-BENCH messages=\(messageCount) write=REJECTED (\(error))")
            return
        }

        let bytes = try Data(contentsOf: url).count
        let write = try milliseconds(3) { try store.transaction { _ in } }
        let open = try milliseconds(3) {
            _ = try ShumConversationStore(ownerID: owner.card.id, key: owner.identity.storageKey, url: url)
        }
        print(String(format: "SHUM-BENCH messages=%d file=%.1fMB bytesPerMessage=%d write=%.0fms open=%.0fms",
                     messageCount, Double(bytes) / 1_048_576, bytes / messageCount, write, open))
        let reopened = try ShumConversationStore(ownerID: owner.card.id, key: owner.identity.storageKey, url: url)
        #expect(reopened.state.messages.count == messageCount)
    }
}
