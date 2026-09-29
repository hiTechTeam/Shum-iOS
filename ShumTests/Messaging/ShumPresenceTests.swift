import BitFoundation
import Foundation
import Testing
@preconcurrency @testable import Shum

/// Records what the message store hands to the relay connection.
@MainActor
private final class FakeInternet: ShumInternetTransport {
    var received: ((ShumPacket, String) -> Void)?
    var connected = true
    var completesImmediately = true
    private(set) var stopCount = 0
    private(set) var sent: [ShumPacket] = []
    private var pending: [(Bool) -> Void] = []

    var presence: [ShumPresenceControl] { sent.compactMap(\.presence) }

    func start() {}
    func stop() { stopCount += 1 }
    func send(_ packet: ShumPacket, to card: ShumContactCard, completion: @escaping (Bool) -> Void) {
        sent.append(packet)
        if completesImmediately { completion(true) } else { pending.append(completion) }
    }
    func acceptPending() {
        let completions = pending
        pending.removeAll()
        completions.forEach { $0(true) }
    }
    func resolve(_ locator: ShumContactLocator, completion: @escaping (Result<ShumResolvedContact, Error>) -> Void) {
        completion(.failure(ShumFailure.contactUnavailable))
    }
    func configureContactLookup(card: @escaping () -> ShumContactCard?, profile: @escaping () -> ShumProfile?) {}
}

/// "In chat" presence is shared only with the contact whose chat is open.
/// Leaving, backgrounding and returning must reach the other side at once.
@Suite("Chat presence", .serialized)
@MainActor
struct ShumPresenceTests {
    typealias Node = ShumPermanentTests.Node
    private let helpers = ShumPermanentTests()

    private func makeNodes(_ names: [String], clock: ShumPermanentTests.Clock) throws -> ([Node], FakeInternet) {
        let nodes = try names.map { try Node($0, clock: clock) }
        let internet = FakeInternet()
        let a = nodes[0]
        a.service = try ShumMessageStore(identity: a.identity, store: a.store, transport: a.wire, wire: a.wire,
                                         card: a.card, internet: internet, now: { clock.date })
        for other in nodes.dropFirst() { try helpers.allowBoth(a, other, clock: clock) }
        return (nodes, internet)
    }

    @Test func openingAndLeavingChatReachTheContactImmediately() throws {
        let clock = ShumPermanentTests.Clock()
        let (nodes, internet) = try makeNodes(["Alice", "Bob"], clock: clock)
        let (a, b) = (nodes[0], nodes[1])
        a.service.open(b.card)
        #expect(internet.presence.map(\.isOnline) == [true])
        a.service.close(b.card)
        #expect(internet.presence.map(\.isOnline) == [true, false])
        #expect(internet.presence.allSatisfy { $0.recipient.id == b.card.id })
    }

    @Test func heartbeatRenewsPresenceBeforeItExpires() throws {
        let clock = ShumPermanentTests.Clock()
        let (nodes, internet) = try makeNodes(["Alice", "Bob"], clock: clock)
        let (a, b) = (nodes[0], nodes[1])
        a.service.open(b.card)
        clock.date.addTimeInterval(10)
        a.service.tick(connected: [], active: true)
        #expect(internet.presence.count == 1)
        clock.date.addTimeInterval(16)
        a.service.tick(connected: [], active: true)
        #expect(internet.presence.map(\.isOnline) == [true, true])
        let lifetime = try #require(internet.presence.first.map { $0.expiresAt - $0.timestamp })
        #expect(lifetime == ShumMessageStore.presenceLifetimeMilliseconds)
        // Renewal leaves room for relay latency before the previous mark expires.
        #expect(Double(lifetime) / 1000 - ShumMessageStore.presenceBroadcastInterval >= 10)
    }

    @Test func backgroundingSendsLeftBeforeClosingTheConnection() throws {
        let clock = ShumPermanentTests.Clock()
        let (nodes, internet) = try makeNodes(["Alice", "Bob"], clock: clock)
        let (a, b) = (nodes[0], nodes[1])
        a.service.open(b.card)
        internet.completesImmediately = false
        a.service.setActive(false)
        #expect(internet.presence.last?.isOnline == false)
        #expect(internet.stopCount == 0, "The relay must receive the signal before disconnecting")
        internet.acceptPending()
        #expect(internet.stopCount == 1)
    }

    @Test func quickReturnSendsInChatImmediately() throws {
        let clock = ShumPermanentTests.Clock()
        let (nodes, internet) = try makeNodes(["Alice", "Bob"], clock: clock)
        let (a, b) = (nodes[0], nodes[1])
        a.service.open(b.card)
        clock.date.addTimeInterval(5)
        a.service.setActive(false)
        clock.date.addTimeInterval(5)
        a.service.setActive(true)
        a.service.tick(connected: [], active: true)
        #expect(internet.presence.map(\.isOnline) == [true, false, true])
    }

    @Test func switchingChatsLeavesOnlyThePreviousOne() throws {
        let clock = ShumPermanentTests.Clock()
        let (nodes, internet) = try makeNodes(["Alice", "Bob", "Carol"], clock: clock)
        let (a, b, c) = (nodes[0], nodes[1], nodes[2])
        a.service.open(b.card)
        a.service.open(c.card)
        // The previous chat may report disappearing after the next one appeared.
        a.service.close(b.card)
        let signals = internet.presence.map { ($0.recipient.id, $0.isOnline) }
        #expect(signals.map(\.0) == [b.card.id, b.card.id, c.card.id])
        #expect(signals.map(\.1) == [true, false, true])
    }

    @Test func receiverShowsInChatUntilLeftOrExpiry() throws {
        let clock = ShumPermanentTests.Clock()
        let (nodes, internet) = try makeNodes(["Alice", "Bob"], clock: clock)
        let (a, b) = (nodes[0], nodes[1])
        a.service.open(b.card)
        b.service.receive(try #require(internet.sent.last), from: nil, nostrSender: a.card.nostrKey)
        #expect(b.service.isInChat(a.card))
        a.service.close(b.card)
        b.service.receive(try #require(internet.sent.last), from: nil, nostrSender: a.card.nostrKey)
        #expect(!b.service.isInChat(a.card))

        clock.date.addTimeInterval(30)
        a.service.open(b.card)
        b.service.receive(try #require(internet.sent.last), from: nil, nostrSender: a.card.nostrKey)
        #expect(b.service.isInChat(a.card))
        clock.date.addTimeInterval(Double(ShumMessageStore.presenceLifetimeMilliseconds) / 1000 + 1)
        b.service.tick(connected: [], active: true)
        #expect(!b.service.isInChat(a.card))
    }
}
