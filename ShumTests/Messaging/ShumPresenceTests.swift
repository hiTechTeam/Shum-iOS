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

/// A nearby contact shows its own notification for a Bluetooth delivery, so
/// the push must not arrive as a second notification for the same message.
@Suite("Push after Bluetooth delivery", .serialized)
@MainActor
struct ShumDirectDeliveryPushTests {
    typealias Node = ShumPermanentTests.Node
    private let helpers = ShumPermanentTests()

    private func makePair(clock: ShumPermanentTests.Clock) throws -> (Node, Node, FakeInternet) {
        let a = try Node("Alice", clock: clock), b = try Node("Bob", clock: clock)
        let internet = FakeInternet()
        a.service = try ShumMessageStore(identity: a.identity, store: a.store, transport: a.wire, wire: a.wire,
                                         card: a.card, internet: internet, now: { clock.date })
        try helpers.allowBoth(a, b, clock: clock)
        return (a, b, internet)
    }

    private func lastSentID(_ node: Node) throws -> String {
        try #require(node.service.state.messages.last { $0.outgoing }).id
    }

    @Test func bluetoothDeliveryNeedsNoPush() throws {
        let clock = ShumPermanentTests.Clock()
        let (a, b, _) = try makePair(clock: clock)
        var pushes: [String] = []
        a.service.requestPush = { _, id, _ in pushes.append(id) }
        helpers.connect(a, b, clock: clock)

        #expect(a.service.send("Рядом", to: b.card))
        helpers.drain([a, b])
        clock.date.addTimeInterval(ShumMessageStore.directDeliveryPushDelay + 1)
        a.service.tick(connected: [b.wire.myPeerID], active: true)

        #expect(a.service.state.messages.last { $0.outgoing }?.status == .delivered)
        #expect(pushes.isEmpty)
    }

    @Test func lostBluetoothDeliveryPushesAfterTheDelay() throws {
        let clock = ShumPermanentTests.Clock()
        let (a, b, _) = try makePair(clock: clock)
        var pushes: [String] = []
        a.service.requestPush = { _, id, _ in pushes.append(id) }
        helpers.connect(a, b, clock: clock)

        #expect(a.service.send("Потеряется", to: b.card))
        a.wire.shumPackets.removeAll() // The Bluetooth copy is lost.
        let id = try lastSentID(a)
        a.service.tick(connected: [b.wire.myPeerID], active: true)
        #expect(pushes.isEmpty)
        clock.date.addTimeInterval(ShumMessageStore.directDeliveryPushDelay + 1)
        a.service.tick(connected: [b.wire.myPeerID], active: true)
        #expect(pushes == [id])
    }

    @Test func backgroundingSendsTheHeldPush() throws {
        let clock = ShumPermanentTests.Clock()
        let (a, b, _) = try makePair(clock: clock)
        var pushes: [String] = []
        a.service.requestPush = { _, id, _ in pushes.append(id) }
        helpers.connect(a, b, clock: clock)

        #expect(a.service.send("Сворачиваю", to: b.card))
        a.wire.shumPackets.removeAll()
        let id = try lastSentID(a)
        a.service.setActive(false)
        #expect(pushes == [id])
    }

    @Test func contactFarAwayGetsThePushAtOnce() throws {
        let clock = ShumPermanentTests.Clock()
        let (a, b, _) = try makePair(clock: clock)
        var pushes: [String] = []
        a.service.requestPush = { _, id, _ in pushes.append(id) }

        #expect(a.service.send("Далеко", to: b.card))
        let id = try lastSentID(a)
        #expect(pushes == [id])
    }
}

/// A message still in transit can be withdrawn, and the contact never keeps it.
@Suite("Cancel sending", .serialized)
@MainActor
struct ShumCancelSendingTests {
    typealias Node = ShumPermanentTests.Node
    private let helpers = ShumPermanentTests()

    private func makePair(clock: ShumPermanentTests.Clock) throws -> (Node, Node, FakeInternet) {
        let a = try Node("Alice", clock: clock), b = try Node("Bob", clock: clock)
        let internet = FakeInternet()
        a.service = try ShumMessageStore(identity: a.identity, store: a.store, transport: a.wire, wire: a.wire,
                                         card: a.card, internet: internet, now: { clock.date })
        a.service.requestPush = { _, _, _ in }
        try helpers.allowBoth(a, b, clock: clock)
        return (a, b, internet)
    }

    /// Hands what Alice gave the relay to Bob, in the given order.
    private func relay(_ packets: [ShumPacket], from a: Node, to b: Node) {
        for packet in packets { b.service.receive(packet, from: nil, nostrSender: a.card.nostrKey) }
    }

    @Test func messageThatNeverLeftThePhoneIsSimplyRemoved() throws {
        let clock = ShumPermanentTests.Clock()
        let (a, b, internet) = try makePair(clock: clock)
        internet.connected = false
        #expect(a.service.send("Черновик", to: b.card))
        let id = try #require(a.service.state.messages.last { $0.outgoing }).id

        #expect(a.service.cancelSending(id))
        #expect(!a.service.state.messages.contains { $0.id == id })
        #expect((a.service.state.retractOutbox ?? []).isEmpty)
        #expect(internet.sent.isEmpty)
    }

    @Test func relayedMessageIsWithdrawnFromTheContact() throws {
        let clock = ShumPermanentTests.Clock()
        let (a, b, internet) = try makePair(clock: clock)
        var retracted: [String] = []
        b.service.onMessagesRetracted = { retracted += $0 }
        #expect(a.service.send("Передумал", to: b.card))
        let id = try #require(a.service.state.messages.last { $0.outgoing }).id
        relay(internet.sent, from: a, to: b)
        #expect(b.service.state.messages.contains { $0.id == id })

        let before = internet.sent.count
        #expect(a.service.cancelSending(id))
        #expect(!a.service.state.messages.contains { $0.id == id })
        let withdrawals = internet.sent.dropFirst(before).compactMap(\.retract)
        #expect(withdrawals.map(\.messageID) == [id])

        relay(Array(internet.sent.dropFirst(before)), from: a, to: b)
        #expect(!b.service.state.messages.contains { $0.id == id })
        #expect(retracted == [id])
        // A late relay copy of the message is ignored.
        relay(Array(internet.sent.prefix(before)), from: a, to: b)
        #expect(!b.service.state.messages.contains { $0.id == id })
        // Once a relay accepted it, the withdrawal leaves the outbox.
        a.service.tick(connected: [], active: true)
        #expect((a.service.state.retractOutbox ?? []).isEmpty)
    }

    @Test func withdrawalArrivingFirstDropsTheMessage() throws {
        let clock = ShumPermanentTests.Clock()
        let (a, b, internet) = try makePair(clock: clock)
        #expect(a.service.send("Обгонит", to: b.card))
        let id = try #require(a.service.state.messages.last { $0.outgoing }).id
        let message = internet.sent
        #expect(a.service.cancelSending(id))

        relay(Array(internet.sent.dropFirst(message.count)), from: a, to: b)
        relay(message, from: a, to: b)
        #expect(!b.service.state.messages.contains { $0.id == id })
    }

    @Test func retryReplacesTheExpiredMessageInsteadOfCopyingIt() throws {
        let clock = ShumPermanentTests.Clock()
        let (a, b, internet) = try makePair(clock: clock)
        internet.connected = false
        #expect(a.service.send("Повтори меня", to: b.card))
        let expired = try #require(a.service.state.messages.last { $0.outgoing }).id
        clock.date.addTimeInterval(24 * 60 * 60 + 1)
        a.service.tick(connected: [], active: true)
        #expect(a.service.state.messages.first { $0.id == expired }?.status == .expired)

        #expect(a.service.resend(expired, to: b.card))
        #expect(!a.service.resend(expired, to: b.card)) // A second tap adds nothing.
        let outgoing = a.service.state.messages.filter(\.outgoing)
        #expect(outgoing.count == 1)
        #expect(outgoing.first?.id != expired)
        #expect(outgoing.first?.text == "Повтори меня")
        #expect(outgoing.first?.status == .queued)
    }

    @Test func deliveredMessageCannotBeCancelled() throws {
        let clock = ShumPermanentTests.Clock()
        let (a, b, _) = try makePair(clock: clock)
        helpers.connect(a, b, clock: clock)
        #expect(a.service.send("Дошло", to: b.card))
        helpers.drain([a, b])
        let message = try #require(a.service.state.messages.last { $0.outgoing })
        #expect(message.status == .delivered)

        #expect(!a.service.cancelSending(message.id))
        #expect(a.service.state.messages.contains { $0.id == message.id })
    }
}
