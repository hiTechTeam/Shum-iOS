import BitFoundation
import Foundation
import Testing
@preconcurrency @testable import Shum

@Suite("Unified chat folders", .serialized)
@MainActor
struct ShumChatDirectoryTests {
    typealias Node = ShumPermanentTests.Node
    typealias Clock = ShumPermanentTests.Clock

    private func rows(_ owner: Node, chats: [ShumPeer] = [], nearby: [ShumPeer] = [], unread: Int = 0) -> [ShumDirectoryEntry] {
        ShumChatDirectory.entries(chats: chats, peers: nearby, permanent: owner.service,
                                  isNearby: { id in nearby.contains { $0.id == id } }, unreadCount: { _ in unread })
    }
    private func peer(_ node: Node) -> ShumPeer {
        ShumPeer(id: node.card.peerID, name: node.card.name, lastConnected: Date())
    }

    @Test func overlappingSourcesProduceOneCardAndIndependentFolders() throws {
        let clock = Clock(), owner = try Node("Owner", clock: clock), person = try Node("Person", clock: clock)
        try owner.service.add(person.card, source: "test")
        try owner.service.recordEncounter(person.card)
        let result = rows(owner, chats: [peer(person)], nearby: [peer(person)], unread: 2)
        #expect(result.count == 1)
        let row = try #require(result.first)
        for folder in [ShumChatFolder.all, .unread, .nearby, .encounters] {
            #expect(row.belongs(to: folder))
        }
        #expect(!row.belongs(to: .invitations))
        owner.service.deleteEncounter(person.card)
        let cleared = try #require(rows(owner, chats: [peer(person)]).first)
        #expect(!cleared.belongs(to: .encounters))
        #expect(cleared.hasChat)
        #expect(owner.store.state.conversations.count == 1)
    }

    @Test func staleConnectionIdentityDoesNotDuplicateKnownPerson() throws {
        let clock = Clock(), owner = try Node("Owner", clock: clock), person = try Node("Person", clock: clock)
        try owner.service.add(person.card, source: "test")
        let connectionPeer = ShumPeer(
            id: PeerID(publicKey: person.card.noiseKey),
            name: person.card.name,
            lastConnected: Date()
        )

        let result = rows(owner, chats: [peer(person)], nearby: [connectionPeer])

        #expect(result.count == 1)
        #expect(result.first?.id == person.card.peerID)
        #expect(result.first?.hasChat == true)
        #expect(result.first?.isNearby == false)
    }

    @Test func unverifiedConnectionIdentityIsNotShownAsAPerson() throws {
        let clock = Clock(), owner = try Node("Owner", clock: clock)
        let connectionPeer = ShumPeer(
            id: PeerID(str: "temporary-session"),
            name: "Ожидание проверки",
            lastConnected: Date()
        )

        #expect(rows(owner, nearby: [connectionPeer]).isEmpty)
    }

    @Test func pendingInvitationIsUnreadUntilAcceptedOrDeclined() throws {
        let clock = Clock(), owner = try Node("Owner", clock: clock), person = try Node("Person", clock: clock)
        try owner.store.transaction { $0.requests = [person.card] }
        let row = try #require(rows(owner).first)
        #expect(row.belongs(to: .invitations) && row.belongs(to: .unread))
        #expect(!row.hasChat && row.unread == 0)
        try owner.service.add(person.card, source: "invitation")
        let accepted = try #require(rows(owner, chats: [peer(person)]).first)
        #expect(!accepted.belongs(to: .invitations) && !accepted.belongs(to: .unread))
        #expect(accepted.hasChat)
    }

    @Test func blockedPeopleDoNotLeakBackThroughAnotherSource() throws {
        let clock = Clock(), owner = try Node("Owner", clock: clock), person = try Node("Person", clock: clock)
        try owner.service.add(person.card, source: "test")
        try owner.service.recordEncounter(person.card)
        try owner.service.setBlocked(person.card, blocked: true)
        #expect(rows(owner, chats: [peer(person)], nearby: [peer(person)]).isEmpty)
    }

    @Test func pinningIsIndependentForEveryFolder() throws {
        let clock = Clock(), owner = try Node("Owner", clock: clock), person = try Node("Person", clock: clock)
        try owner.service.add(person.card, source: "test")
        #expect(try owner.service.togglePinned(person.card, in: ShumChatFolder.all.pinKey))
        #expect(owner.service.isPinned(person.card, in: ShumChatFolder.all.pinKey))
        #expect(!owner.service.isPinned(person.card, in: ShumChatFolder.nearby.pinKey))
        try owner.service.deleteConversation(with: person.card)
        let row = try #require(rows(owner).first)
        #expect(!row.hasChat)
        #expect(owner.service.isPinned(person.card, in: ShumChatFolder.all.pinKey))
        #expect(owner.store.state.conversations.isEmpty)
    }
}
