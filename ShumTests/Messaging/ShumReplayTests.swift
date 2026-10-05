import BitFoundation
import CryptoKit
import Foundation
import Testing
@preconcurrency @testable import Shum

/// Records what the message store hands to the relay connection.
@MainActor
private final class FakeInternet: ShumInternetTransport {
    var received: ((ShumPacket, String) -> Void)?
    var connected = true
    private(set) var sent: [ShumPacket] = []

    func start() {}
    func stop() {}
    func send(_ packet: ShumPacket, to card: ShumContactCard, completion: @escaping (Bool) -> Void) {
        sent.append(packet)
        completion(true)
    }
    func resolve(_ locator: ShumContactLocator, completion: @escaping (Result<ShumResolvedContact, Error>) -> Void) {
        completion(.failure(ShumFailure.contactUnavailable))
    }
    func configureContactLookup(card: @escaping () -> ShumContactCard?, profile: @escaping () -> ShumProfile?) {}
}

/// Relays send the last days of events again on every launch. Handling them
/// again must cost nothing and must not change what the user sees.
@Suite("Relay replays", .serialized)
@MainActor
struct ShumReplayTests {
    private let helpers = ShumPermanentTests()

    private func eventID(_ index: Int) -> String {
        SHA256.hash(data: Data("event-\(index)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ShumReplayTests-\(UUID().uuidString)")
            .appendingPathComponent("nostr-handled.bin")
    }

    @Test func handledEventsSurviveARelaunch() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = ShumHandledEvents(url: url)
        first.insert(eventID(1))
        first.save(synchronously: true)
        let next = ShumHandledEvents(url: url)
        #expect(next.contains(eventID(1)))
        #expect(!next.contains(eventID(2)))
    }

    @Test func handledEventsAreForgottenAfterTheFetchWindow() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let clock = ShumPermanentTests.Clock()
        let first = ShumHandledEvents(url: url, now: { clock.date })
        first.insert(eventID(1))
        first.save(synchronously: true)
        clock.date.addTimeInterval(ShumHandledEvents.lifetime + 60)
        #expect(!ShumHandledEvents(url: url, now: { clock.date }).contains(eventID(1)))
    }

    @Test func handledEventsIgnoreMalformedIDsAndStayBounded() {
        let clock = ShumPermanentTests.Clock()
        let events = ShumHandledEvents(url: nil, now: { clock.date })
        events.insert("not-an-event-id")
        #expect(events.count == 0)
        #expect(!events.contains("not-an-event-id"))
        for index in 0...(ShumHandledEvents.limit + 1_000) {
            clock.date.addTimeInterval(1)
            events.insert(eventID(index))
        }
        #expect(events.count == ShumHandledEvents.limit)
        // The oldest are dropped first.
        #expect(events.contains(eventID(ShumHandledEvents.limit + 1_000)))
        #expect(!events.contains(eventID(0)))
    }

    @Test func aRepeatedCopyOfAKnownMessageIsAcknowledgedAgainWithoutADuplicate() throws {
        let clock = ShumPermanentTests.Clock()
        let a = try ShumPermanentTests.Node("Alice", clock: clock)
        let b = try ShumPermanentTests.Node("Bob", clock: clock)
        let internet = FakeInternet()
        a.service = try ShumMessageStore(identity: a.identity, store: a.store, transport: a.wire, wire: a.wire,
                                         card: a.card, internet: internet, now: { clock.date })
        try helpers.allowBoth(a, b, clock: clock)

        #expect(a.service.send("привет", to: b.card))
        let packet = try #require(internet.sent.last { $0.envelope != nil })
        let id = try #require(packet.envelope?.id)
        b.service.receive(packet, from: nil, nostrSender: a.card.nostrKey)
        #expect(b.store.state.messages.filter { $0.id == id }.count == 1)

        // The receipt reached the relay.
        try b.store.transaction { state in
            for index in state.receipts.indices where state.receipts[index].receipt.envelopeID == id {
                state.receipts[index].nostrAccepted = true
                state.receipts[index].lastAttempt = clock.date
            }
        }
        clock.date.addTimeInterval(11)
        b.service.receive(packet, from: nil, nostrSender: a.card.nostrKey)

        #expect(b.store.state.messages.filter { $0.id == id }.count == 1)
        let receipt = try #require(b.store.state.receipts.first { $0.receipt.envelopeID == id })
        #expect(!receipt.nostrAccepted, "A sender retry means the receipt may be lost, so it goes out again")
        #expect(receipt.lastAttempt == .distantPast)
    }
}
