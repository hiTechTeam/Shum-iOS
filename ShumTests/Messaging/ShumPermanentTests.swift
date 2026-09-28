import BitFoundation
import CryptoKit
import Foundation
import Testing
@preconcurrency @testable import Shum

@Suite("Shum permanent offline conversations", .serialized)
@MainActor
struct ShumPermanentTests {
    final class Clock { var date = Date() }
    @MainActor final class Node {
        let wire = MockTransport()
        let identity: ShumIdentityService
        let card: ShumContactCard
        var store: ShumConversationStore
        var service: ShumMessageStore
        init(_ name: String, clock: Clock, url: URL? = nil) throws {
            identity = try ShumIdentityService(transport: wire, keychain: wire.mockKeychain, bridge: NostrIdentityBridge(keychain: wire.mockKeychain))
            card = try identity.card(name: name, bio: "Привет")
            wire.myPeerID = PeerID(publicKey: card.noiseKey)
            store = try ShumConversationStore(ownerID: card.id, key: identity.storageKey, url: url)
            service = try ShumMessageStore(identity: identity, store: store, transport: wire, wire: wire, card: card, internet: nil, now: { clock.date })
        }
    }
    func connect(_ a: Node, _ b: Node, clock: Clock) {
        a.wire.connectedPeers = [b.wire.myPeerID]; b.wire.connectedPeers = [a.wire.myPeerID]
        a.wire.shumSessionKeys[b.wire.myPeerID] = b.card.noiseKey
        b.wire.shumSessionKeys[a.wire.myPeerID] = a.card.noiseKey
        a.service.tick(connected: [b.wire.myPeerID], active: true)
        b.service.tick(connected: [a.wire.myPeerID], active: true)
        drain([a,b])
    }
    func drain(_ nodes: [Node]) {
        var work = true, iterations = 0
        while work && iterations < 100 {
            work = false; iterations += 1
            for node in nodes {
                let packets = node.wire.shumPackets; node.wire.shumPackets.removeAll()
                for (to, data) in packets {
                    if let target = nodes.first(where: { $0.wire.myPeerID == to }), node.wire.connectedPeers.contains(to) {
                        work = true; target.service.receiveBytes(data, from: node.wire.myPeerID)
                    }
                }
            }
        }
        #expect(iterations < 100)
    }
    func allow(_ owner: Node, to contact: Node, clock: Clock) throws {
        try owner.service.add(contact.card, source: "test")
        try owner.store.transaction { state in
            if state.invitationStates == nil { state.invitationStates = [:] }
            state.invitationStates?[contact.card.id] = ShumInvitationState(
                phase: .accepted,
                updatedAt: Int64(clock.date.timeIntervalSince1970 * 1000),
                eventID: "test-\(UUID().uuidString)"
            )
        }
    }
    func allowBoth(_ a: Node, _ b: Node, clock: Clock) throws {
        try allow(a, to: b, clock: clock)
        try allow(b, to: a, clock: clock)
    }
    @Test func lostDiscoveryCardRetriesPromptlyThenReturnsToQuietRefresh() throws {
        let clock = Clock()
        let a = try Node("Аня", clock: clock)
        let b = try Node("Борис", clock: clock)
        a.wire.connectedPeers = [b.wire.myPeerID]
        b.wire.connectedPeers = [a.wire.myPeerID]
        a.wire.shumSessionKeys[b.wire.myPeerID] = b.card.noiseKey
        b.wire.shumSessionKeys[a.wire.myPeerID] = a.card.noiseKey
        a.service.tick(connected: [b.wire.myPeerID], active: true)
        #expect(a.wire.shumPackets.count == 1)
        a.wire.shumPackets.removeAll() // First card was lost during setup.
        clock.date.addTimeInterval(1)
        a.service.tick(connected: [b.wire.myPeerID], active: true)
        #expect(a.wire.shumPackets.isEmpty)
        clock.date.addTimeInterval(1)
        a.service.tick(connected: [b.wire.myPeerID], active: true)
        #expect(a.wire.shumPackets.count == 1)
        drain([a, b])
        #expect(a.service.nearby[b.wire.myPeerID] == b.card)
        #expect(b.service.nearby[a.wire.myPeerID] == a.card)
        clock.date.addTimeInterval(2)
        a.service.tick(connected: [b.wire.myPeerID], active: true)
        #expect(a.wire.shumPackets.isEmpty)
        a.service.tick(connected: [], active: true)
        #expect(a.service.nearby.isEmpty)
        a.service.tick(connected: [b.wire.myPeerID], active: true)
        #expect(a.wire.shumPackets.count == 1)
    }

    @Test("Offline QR contains the complete signed avatar and persists on the receiver")
    func offlineSeedInvitation() throws {
        let clock = Clock()
        let alice = try Node("Alice", clock: clock)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bob = try Node("Bob", clock: clock, url: url)
        try alice.service.updateProfile(name: "Alice", bio: "Offline", avatarSeed: UInt64.max)
        let original = alice.service.ownCard
        guard case let .card(decoded) = try ShumInvitationPayload.parse(original.invitation()) else {
            Issue.record("QR required a network lookup"); return
        }
        #expect(decoded == original)
        #expect(try original.invitation().absoluteString.utf8.count < 600)
        try bob.service.add(decoded, source: "qr")
        #expect(bob.service.invitationPhase(for: decoded) == .ready)
        #expect(bob.wire.shumPackets.isEmpty)
        let reopened = try ShumConversationStore(ownerID: bob.card.id, key: bob.identity.storageKey, url: url)
        let saved = try #require(reopened.state.contacts.first?.card)
        #expect(saved == original)
        #expect(reopened.state.contacts.first?.avatar == nil)
        #expect(ShumPixelAvatarGenerator.data(seed: saved.avatarSeed!) == ShumPixelAvatarGenerator.data(seed: UInt64.max))
        var tampered = decoded
        tampered.profileRevision = 100
        #expect(throws: (any Error).self) { try tampered.validate() }
        tampered = decoded
        tampered.avatarVersion = 2
        #expect(throws: (any Error).self) { try tampered.validate() }
    }

    @Test("Old QR, BLE cards and internet packets cannot roll back a profile")
    func profileVersionOrdering() throws {
        let clock = Clock()
        let a = try Node("Alice", clock: clock), b = try Node("Bob", clock: clock)
        try allowBoth(a, b, clock: clock)
        try a.service.updateProfile(name: "New Alice", bio: "", avatarSeed: 77)
        let fresh = a.service.ownCard
        b.service.receive(ShumPacket(card: fresh), from: nil, nostrSender: fresh.nostrKey)
        try b.service.add(a.card, source: "old-qr")
        b.service.receive(ShumPacket(card: a.card), from: nil, nostrSender: a.card.nostrKey)
        connect(a, b, clock: clock)
        b.service.receive(ShumPacket(card: a.card), from: a.wire.myPeerID, nostrSender: nil)
        #expect(b.service.card(for: a.card.peerID) == fresh)
        #expect(b.service.nearby[a.wire.myPeerID] == fresh)
        #expect(b.service.invitationPhase(for: fresh) == .accepted)
    }

    @Test("BLE retries persist and acknowledgement clears only the delivered revision")
    func durableProfileUpdates() throws {
        let clock = Clock()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try Node("Alice", clock: clock, url: url), b = try Node("Bob", clock: clock)
        try allowBoth(a, b, clock: clock)
        try a.service.updateProfile(name: "Alice", bio: "", avatarSeed: 10)
        try a.service.updateProfile(name: "Alice", bio: "", avatarSeed: 20)
        #expect(a.service.state.profileOutbox?.count == 1)
        let latest = a.service.ownCard
        a.store = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        a.service = try ShumMessageStore(identity: a.identity, store: a.store, transport: a.wire,
            wire: a.wire, card: latest, internet: nil, now: { clock.date })
        #expect(a.service.ownCard == latest)
        connect(a, b, clock: clock)
        clock.date.addTimeInterval(2)
        a.service.tick(connected: [b.wire.myPeerID], active: true)
        b.service.tick(connected: [a.wire.myPeerID], active: true)
        drain([a, b])
        #expect(b.service.card(for: a.card.peerID)?.avatarSeed == 20)
        #expect(a.service.state.profileOutbox?.isEmpty == true)
        #expect(b.service.state.profileOutbox?.isEmpty == true)
    }

    @Test("Encrypted internet profile protocol authenticates acknowledgements and reconciles restored counters")
    func profileSyncAndRestore() throws {
        let clock = Clock()
        let a = try Node("Alice", clock: clock), b = try Node("Bob", clock: clock)
        try allowBoth(a, b, clock: clock)
        let newer = try a.identity.card(name: "Alice", bio: "", avatarSeed: 55, revision: 90)
        var sync = ShumProfileSync(sender: b.service.ownCard, recipientID: a.card.id,
            knownRecipient: newer, requestsReply: false)
        sync.signature = try #require(b.wire.noiseSignData(sync.signingBytes()))
        a.service.receive(ShumPacket(profileSync: sync), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.service.ownCard.profileRevision == 91)
        #expect(a.service.ownCard.avatarSeed == a.card.avatarSeed)
        #expect(a.service.state.ownProfileCard == a.service.ownCard)
        #expect(a.service.state.profileOutbox?.count == 1)
        // A forged acknowledgement cannot clear the queue.
        sync.knownRecipient = a.service.ownCard
        a.service.receive(ShumPacket(profileSync: sync), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.service.state.profileOutbox?.count == 1)
        sync.signature = try #require(b.wire.noiseSignData(sync.signingBytes()))
        a.service.receive(ShumPacket(profileSync: sync), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.service.state.profileOutbox?.isEmpty == true)
    }

    @Test("Legacy locator links still decode and profile payloads reject trailing bytes")
    func invitationCompatibilityAndBounds() throws {
        let old = try #require(URL(string: "shum://c2/AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"))
        guard case .locator = try ShumInvitationPayload.parse(old) else { Issue.record("Legacy locator rejected"); return }
        let node = try Node("Alice", clock: Clock())
        let valid = try node.card.invitation().absoluteString
        let extra = try #require(URL(string: valid + "AAAA"))
        #expect(throws: (any Error).self) { try ShumInvitationPayload.parse(extra) }
        let truncated = try #require(URL(string: String(valid.dropLast(20))))
        #expect(throws: (any Error).self) { try ShumInvitationPayload.parse(truncated) }
    }

    @Test func identityAndQRStayStableAndRejectTampering() throws {
        let a = try Node("Аня", clock: Clock())
        let restored = try ShumIdentityService(transport: a.wire, keychain: a.wire.mockKeychain, bridge: NostrIdentityBridge(keychain: a.wire.mockKeychain))
        let restoredCard = try restored.card(name: "Аня", bio: "Привет")
        #expect(restoredCard.id == a.card.id)
        #expect(restoredCard.noiseKey == a.card.noiseKey)
        #expect(restoredCard.signingKey == a.card.signingKey)
        #expect(restoredCard.nostrKey == a.card.nostrKey)
        #expect(try restoredCard.signedBytes() == a.card.signedBytes())
        try restoredCard.validate()
        let compactInvitation = try ShumInvitationPayload.parse(a.card.invitation())
        guard case let .card(profile) = compactInvitation else {
            Issue.record("The invitation must contain an offline profile")
            return
        }
        #expect(profile == a.card)
        let legacyCard = try ShumContactCard.parse(a.card.legacyInvitation())
        #expect(legacyCard.id == a.card.id && legacyCard.avatarSeed == nil)
        #expect(legacyCard.signature == a.card.signature)
        try legacyCard.validate()
        var tampered = a.card; tampered.nostrKey = String(repeating: "0", count: 64)
        #expect(throws: (any Error).self) { try tampered.validate() }
        a.wire.mockKeychain.simulatedReadError = .deviceLocked
        #expect(throws: (any Error).self) { _ = try ShumIdentityService(transport: a.wire, keychain: a.wire.mockKeychain, bridge: NostrIdentityBridge(keychain: a.wire.mockKeychain)) }
    }
    @Test func sharedInvitationUsesHTTPSWithoutSendingContactToServer() throws {
        let a = try Node("Аня", clock: Clock())
        let base = try #require(URL(string: "https://example.test/old?ignored=1#old"))
        let shared = try a.card.sharingInvitation(baseURL: base)
        #expect(shared.scheme == "https")
        #expect(shared.host == "example.test")
        #expect(shared.path == "/invite")
        #expect(shared.query == nil)
        let fragment = try #require(shared.fragment)
        let direct = try #require(URL(string: "shum://" + fragment))
        #expect(direct == (try a.card.invitation()))
        guard case let .card(profile) = try ShumInvitationPayload.parse(shared) else {
            Issue.record("Shared invitation must open the original contact")
            return
        }
        #expect(profile == a.card)
        #expect(!shared.absoluteString.contains(a.card.name))
        let insecure = try #require(URL(string: "http://example.test"))
        #expect(throws: (any Error).self) { try a.card.sharingInvitation(baseURL: insecure) }
    }

    @Test("Contact card carries a separately signed seed and keeps the old card signature")
    func signedAvatarSeed() throws {
        let node = try Node("Аня", clock: Clock())
        let card = try node.identity.card(name: node.card.name, bio: "", avatarSeed: 42)
        #expect(card.avatarSeed == 42)
        try card.validate()

        var changed = card
        changed.avatarSeed = 43
        #expect(throws: (any Error).self) { try changed.validate() }

        var oldShape = card
        oldShape.profileRevision = nil
        oldShape.profileSignature = nil
        oldShape.avatarSeed = nil
        oldShape.avatarVersion = nil
        oldShape.avatarSeedSignature = nil
        try oldShape.validate()
        #expect(try oldShape.signedBytes() == card.signedBytes())
    }

    @Test("Internet invitation keeps its signed control but sends no image")
    func invitationWithoutPhotoSurvivesRestart() throws {
        let clock = Clock()
        let senderURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let receiverURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: senderURL)
            try? FileManager.default.removeItem(at: receiverURL)
        }
        let a = try Node("Аня", clock: clock, url: senderURL)
        let b = try Node("Борис", clock: clock, url: receiverURL)
        a.service.configureContactLookup {
            ShumProfile(name: a.card.name, avatarSeed: 42).rendered()
        }
        #expect(a.service.sendInvitation(b.card))
        let restoredOutbox = try ShumConversationStore(ownerID: a.card.id,
            key: a.identity.storageKey, url: senderURL)
        let pending = try #require(restoredOutbox.state.invitationOutbox?.first)
        #expect(pending.avatar == nil)
        let packet = ShumPacket(invitation: pending.control)
        let bytes = try ShumCoding.encode(packet)
        #expect(bytes.count < 10_000)
        let event = try NostrProtocol.createPrivateMessage(
            content: ShumWireProtocol.relayPrefix + bytes.base64EncodedString(),
            recipientPubkey: b.card.nostrKey, senderIdentity: a.identity.nostr)
        let decoded = try NostrProtocol.decryptPrivateMessage(giftWrap: event,
            recipientIdentity: b.identity.nostr)
        let receivedBytes = try #require(Data(base64Encoded:
            String(decoded.content.dropFirst(ShumWireProtocol.relayPrefix.count))))
        b.service.receive(try JSONDecoder().decode(ShumPacket.self, from: receivedBytes),
            from: nil, nostrSender: decoded.senderPubkey)
        #expect(b.service.invitationPhase(for: a.card) == .incomingPending)
        #expect(b.service.avatar(for: a.card) == nil)
        b.store = try ShumConversationStore(ownerID: b.card.id,
            key: b.identity.storageKey, url: receiverURL)
        b.service = try ShumMessageStore(identity: b.identity, store: b.store,
            transport: b.wire, wire: b.wire, card: b.card, internet: nil,
            now: { clock.date })
        #expect(b.service.acceptInvitation(a.card))
        #expect(b.store.state.contacts.first?.avatar == nil)
    }

    @Test("Bluetooth invitations stay image-free through decline and acceptance")
    func bluetoothInvitationWithoutPhoto() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock)
        let b = try Node("Борис", clock: clock)
        a.service.configureContactLookup {
            ShumProfile(name: a.card.name, avatarSeed: 10).rendered()
        }
        connect(a, b, clock: clock)
        #expect(a.service.sendInvitation(b.card))
        #expect(a.store.state.invitationOutbox?.first?.avatar == nil)
        drain([a, b])
        #expect(b.service.invitationPhase(for: a.card) == .incomingPending)
        #expect(b.service.declineInvitation(a.card))
        drain([a, b])
        #expect(b.service.acceptInvitation(a.card))
        drain([a, b])
        #expect(a.service.invitationPhase(for: b.card) == .accepted)
        #expect(a.service.avatar(for: b.card) == nil)
        #expect(b.service.avatar(for: a.card) == nil)
    }

    @Test func invitationCanBeDeclinedAndAcceptedLater() throws {
        let clock = Clock()
        let a = try Node("Аня", clock: clock)
        let b = try Node("Борис", clock: clock)
        try a.service.add(b.card, source: "QR")
        try b.service.add(a.card, source: "QR")
        connect(a, b, clock: clock)

        #expect(a.service.invitationPhase(for: b.card) == .ready)
        #expect(!a.service.send("Рано", to: b.card))
        #expect(a.service.sendInvitation(b.card))
        drain([a, b])
        #expect(a.service.invitationPhase(for: b.card) == .outgoingPending)
        #expect(b.service.invitationPhase(for: a.card) == .incomingPending)

        #expect(b.service.declineInvitation(a.card))
        drain([a, b])
        #expect(a.service.invitationPhase(for: b.card) == .declinedByPeer)
        #expect(b.service.invitationPhase(for: a.card) == .declinedLocally)
        #expect(!a.service.send("Всё ещё рано", to: b.card))

        #expect(b.service.acceptInvitation(a.card))
        drain([a, b])
        #expect(a.service.invitationPhase(for: b.card) == .accepted)
        #expect(b.service.invitationPhase(for: a.card) == .accepted)
        #expect(a.service.send("Теперь можно", to: b.card))
        drain([a, b])
        #expect(b.store.state.messages.last?.text == "Теперь можно")
    }

    @Test(arguments: [true, false])
    func declineThenAcceptDoesNotReverseInvitationAfterRestart(legacyCardFirst: Bool) throws {
        let clock = Clock()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try Node("iPhone 14", clock: clock, url: url)
        let b = try Node("iPhone 11", clock: clock)
        #expect(a.service.sendInvitation(b.card))
        let request = try #require(a.store.state.invitationOutbox?.first?.control)
        b.service.receive(ShumPacket(invitation: request), from: nil, nostrSender: a.card.nostrKey)
        #expect(b.service.declineInvitation(a.card))
        let decline = try #require(b.store.state.invitationOutbox?.first?.control)
        a.service.receive(ShumPacket(invitation: decline), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.service.invitationPhase(for: b.card) == .declinedByPeer)
        #expect(a.store.state.invitationOutbox?.isEmpty == true)
        a.service.setActive(false)
        #expect(b.service.acceptInvitation(a.card))
        let acceptance = try #require(b.store.state.invitationOutbox?.first?.control)

        // Reconnect after the reply was published; either relay event may arrive first.
        a.service.retire()
        a.store = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        a.service = try ShumMessageStore(identity: a.identity, store: a.store, transport: a.wire, wire: a.wire,
            card: a.card, internet: nil, now: { clock.date })
        a.service.setActive(true)
        let legacy = ShumPacket(card: b.card)
        if legacyCardFirst {
            a.service.receive(legacy, from: nil, nostrSender: b.card.nostrKey)
            #expect(a.service.invitationPhase(for: b.card) == .declinedByPeer)
            #expect(a.store.state.requests.isEmpty)
        }
        a.service.receive(ShumPacket(invitation: acceptance), from: nil, nostrSender: b.card.nostrKey)
        a.service.receive(legacy, from: nil, nostrSender: b.card.nostrKey)
        // Duplicates and an old refusal must not undo the confirmed acceptance.
        a.service.receive(ShumPacket(invitation: decline), from: nil, nostrSender: b.card.nostrKey)
        a.service.receive(ShumPacket(invitation: acceptance), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.service.invitationPhase(for: b.card) == .accepted)
        #expect(b.service.invitationPhase(for: a.card) == .accepted)
        #expect(a.store.state.requests.isEmpty)
        #expect(a.service.send("Теперь можно писать", to: b.card))
        let restored = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(restored.state.invitationStates?[b.card.id]?.phase == .accepted)
    }

    @Test(arguments: [true, false])
    func oldReversedLegacyInvitationRequiresEvidenceOfOurRequest(weInvited: Bool) throws {
        let clock = Clock()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try Node("Аня", clock: clock, url: url), b = try Node("Борис", clock: clock)
        if weInvited {
            #expect(a.service.sendInvitation(b.card))
        } else {
            try a.service.add(b.card, source: "QR")
        }
        // Persist the state produced by build 12 when the legacy card won the race.
        try a.store.transaction { state in
            state.requests = [b.card]
            state.invitationOutbox = []
            state.invitationStates?[b.card.id] = ShumInvitationState(
                phase: .incomingPending, updatedAt: 1, eventID: "legacy-\(UUID().uuidString)")
        }
        a.service.retire()
        a.store = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        a.service = try ShumMessageStore(identity: a.identity, store: a.store, transport: a.wire, wire: a.wire,
            card: a.card, internet: nil, now: { clock.date })
        let timestamp = Int64(clock.date.timeIntervalSince1970 * 1000)
        var acceptance = ShumInvitationControl(id: UUID().uuidString, sender: b.card, recipient: a.card,
            action: .accept, timestamp: timestamp, expiresAt: timestamp + 60_000)
        acceptance.signature = try #require(b.wire.noiseSignData(acceptance.signingBytes()))
        a.service.receive(ShumPacket(invitation: acceptance), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.service.invitationPhase(for: b.card) == (weInvited ? .accepted : .incomingPending))
        #expect(a.service.canMessage(b.card) == weInvited)
        #expect(a.store.state.requests.isEmpty == weInvited)
    }

    @Test func legacyInvitationStillIntroducesAnUnknownPerson() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock)
        a.service.receive(ShumPacket(card: b.card), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.service.invitationPhase(for: b.card) == .incomingPending)
        #expect(a.store.state.requests.map(\.id) == [b.card.id])
        a.service.receive(ShumPacket(card: b.card), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.store.state.requests.count == 1)
    }

    @Test func simultaneousInvitationsConvergeToOneRequester() throws {
        let clock = Clock()
        let a = try Node("Аня", clock: clock)
        let b = try Node("Борис", clock: clock)
        try a.service.add(b.card, source: "QR")
        try b.service.add(a.card, source: "QR")
        connect(a, b, clock: clock)

        #expect(a.service.sendInvitation(b.card))
        #expect(b.service.sendInvitation(a.card))
        drain([a, b])

        let requester = a.card.id < b.card.id ? a : b
        let recipient = requester === a ? b : a
        #expect(requester.service.invitationPhase(for: recipient.card) == .outgoingPending)
        #expect(recipient.service.invitationPhase(for: requester.card) == .incomingPending)
        #expect(!requester.store.state.requests.contains { $0.id == recipient.card.id })
        #expect(recipient.store.state.requests.contains { $0.id == requester.card.id })

        #expect(recipient.service.acceptInvitation(requester.card))
        drain([a, b])
        #expect(a.service.invitationPhase(for: b.card) == .accepted)
        #expect(b.service.invitationPhase(for: a.card) == .accepted)
    }

    @Test func legacyCardCannotReplaceOutgoingInvitationBeforeSignedAcceptance() throws {
        let clock = Clock()
        let a = try Node("Аня", clock: clock)
        let b = try Node("Борис", clock: clock)
        try a.service.add(b.card, source: "QR")
        try b.service.add(a.card, source: "QR")
        #expect(a.service.sendInvitation(b.card))

        a.service.receive(
            ShumPacket(card: b.card),
            from: nil,
            nostrSender: b.card.nostrKey
        )
        #expect(a.service.invitationPhase(for: b.card) == .outgoingPending)
        #expect(a.store.state.invitationOutbox?.contains {
            $0.control.recipient.id == b.card.id
                && $0.control.action == .request
        } == true)

        let request = try #require(a.store.state.invitationOutbox?.first?.control)
        b.service.receive(
            ShumPacket(invitation: request),
            from: nil,
            nostrSender: a.card.nostrKey
        )
        #expect(b.service.acceptInvitation(a.card))
        let acceptance = try #require(b.store.state.invitationOutbox?.first?.control)
        a.service.receive(
            ShumPacket(invitation: acceptance),
            from: nil,
            nostrSender: b.card.nostrKey
        )
        #expect(a.service.invitationPhase(for: b.card) == .accepted)
    }

    @Test func simultaneousLegacyCardsWaitForSignedRequests() throws {
        let clock = Clock()
        let a = try Node("Аня", clock: clock)
        let b = try Node("Борис", clock: clock)
        try a.service.add(b.card, source: "QR")
        try b.service.add(a.card, source: "QR")
        #expect(a.service.sendInvitation(b.card))
        #expect(b.service.sendInvitation(a.card))
        a.service.receive(ShumPacket(card: b.card), from: nil,
                          nostrSender: b.card.nostrKey)
        b.service.receive(ShumPacket(card: a.card), from: nil,
                          nostrSender: a.card.nostrKey)
        #expect(a.service.invitationPhase(for: b.card) == .outgoingPending)
        #expect(b.service.invitationPhase(for: a.card) == .outgoingPending)
        let requestA = try #require(a.store.state.invitationOutbox?.first?.control)
        let requestB = try #require(b.store.state.invitationOutbox?.first?.control)
        a.service.receive(ShumPacket(invitation: requestB), from: nil,
                          nostrSender: b.card.nostrKey)
        b.service.receive(ShumPacket(invitation: requestA), from: nil,
                          nostrSender: a.card.nostrKey)
        let requester = a.card.id < b.card.id ? a : b
        let recipient = requester === a ? b : a
        #expect(requester.service.invitationPhase(for: recipient.card) == .outgoingPending)
        #expect(recipient.service.invitationPhase(for: requester.card) == .incomingPending)
    }

    @Test func unsolicitedAcceptanceCannotUnlockAChat() throws {
        let clock = Clock()
        let a = try Node("Аня", clock: clock)
        let b = try Node("Борис", clock: clock)
        try a.service.add(b.card, source: "QR")
        connect(a, b, clock: clock)

        let timestamp = Int64(clock.date.timeIntervalSince1970 * 1000)
        var control = ShumInvitationControl(
            id: UUID().uuidString,
            sender: b.card,
            recipient: a.card,
            action: .accept,
            timestamp: timestamp,
            expiresAt: timestamp + ShumMessageStore.invitationLifetimeMilliseconds
        )
        control.signature = try #require(b.wire.noiseSignData(control.signingBytes()))
        a.service.receive(
            ShumPacket(invitation: control),
            from: b.wire.myPeerID,
            nostrSender: nil
        )

        #expect(a.service.invitationPhase(for: b.card) == .ready)
        #expect(!a.service.send("Нельзя", to: b.card))
    }
    @Test func durableOutboxAndHistoryAreEncryptedAndFailClosed() throws {
        let clock = Clock(), url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".enc")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try Node("Аня", clock: clock, url: url), b = try Node("Борис", clock: clock)
        try allow(a, to: b, clock: clock)
        #expect(a.service.send("Секретная история 🌍", to: b.card))
        #expect(a.store.state.messages[0].status == .queued)
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data("Секретная история".utf8)) == nil)
        let restored = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(restored.state.messages[0].text == "Секретная история 🌍")
        #expect(restored.state.contacts[0].card == b.card)
        #expect(restored.state.conversations.count == 1)
        #expect(throws: (any Error).self) { _ = try ShumConversationStore(ownerID: a.card.id, key: SymmetricKey(size: .bits256), url: url) }
        try Data([1,2,3]).write(to: url)
        #expect(throws: (any Error).self) { _ = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url) }
        #expect(try Data(contentsOf: url) == Data([1,2,3]))
    }

    @Test func encounterHistoryAndFolderPinsAreDurable() throws {
        let clock = Clock()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".enc")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = try Node("Аня", clock: clock, url: url)
        let b = try Node("Борис", clock: clock)
        let avatar = Data([1, 2, 3, 4])

        try a.service.recordEncounter(b.card, avatar: avatar)
        #expect(a.service.encounterHistory.count == 1)
        #expect(a.service.encounterHistory[0].seenCount == 1)
        #expect(a.service.unviewedEncounterCount == 1)

        clock.date.addTimeInterval(61)
        try a.service.recordEncounter(b.card, avatar: avatar)
        #expect(a.service.encounterHistory[0].seenCount == 2)

        #expect(try a.service.togglePinned(b.card, in: "encounters"))
        #expect(a.service.isPinned(b.card, in: "encounters"))
        a.service.markEncountersViewed()
        #expect(a.service.unviewedEncounterCount == 0)

        let restored = try ShumConversationStore(
            ownerID: a.card.id,
            key: a.identity.storageKey,
            url: url
        )
        #expect(restored.state.encounters?.first?.card == b.card)
        #expect(restored.state.encounters?.first?.avatar == avatar)
        #expect(restored.state.pinnedDirectoryEntries?["encounters"]?.contains(b.card.id) == true)

        a.service.deleteEncounter(b.card)
        #expect(a.service.encounterHistory.isEmpty)
        #expect(!a.service.isPinned(b.card, in: "encounters"))
    }
    @Test func openingUnreadHistoryCommitsReceiptsOnceAndReopeningDoesNotRepublish() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".enc")
        defer { try? FileManager.default.removeItem(at: url) }
        let b = try Node("Борис", clock: clock, url: url)
        try allowBoth(a, b, clock: clock)
        connect(a, b, clock: clock)
        for index in 0..<8 {
            clock.date.addTimeInterval(2)
            #expect(a.service.send("Unread \(index)", to: b.card))
            drain([a, b])
        }
        #expect(b.store.state.messages.filter(\.unread).count == 8)
        let before = b.service.revision
        b.service.open(a.card)
        #expect(b.service.revision == before + 1)
        #expect(b.store.state.messages.allSatisfy { !$0.unread })
        #expect(b.store.state.receipts.filter { $0.receipt.read }.count == 8)
        for receipt in b.store.state.receipts where receipt.receipt.read {
            try receipt.receipt.validate(at: clock.date)
        }
        let restored = try ShumConversationStore(ownerID: b.card.id, key: b.identity.storageKey, url: url)
        #expect(restored.state.messages.allSatisfy { !$0.unread })
        #expect(restored.state.receipts.filter { $0.receipt.read }.count == 8)
        b.service.open(nil)
        b.service.open(a.card)
        #expect(b.service.revision == before + 1)
    }

    @Test func failedReadSaveKeepsUnreadMessagesAndDeliveryReceipts() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let b = try Node("Борис", clock: clock, url: directory.appendingPathComponent("state.enc"))
        try allowBoth(a, b, clock: clock)
        connect(a, b, clock: clock)
        #expect(a.service.send("Unread", to: b.card))
        drain([a, b])
        let before = b.service.revision
        // Make this test database's parent unwritable as a directory.
        try FileManager.default.removeItem(at: directory)
        try Data().write(to: directory)
        var reportedFailure = false
        b.service.onError = { _ in reportedFailure = true }
        b.service.open(a.card)
        #expect(reportedFailure)
        #expect(b.service.revision == before)
        #expect(b.store.state.messages.first?.unread == true)
        #expect(b.store.state.receipts.allSatisfy { !$0.receipt.read })
    }

    @Test func directDeliveryReadAndSessionChange() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock)
        try allowBoth(a, b, clock: clock)
        connect(a,b,clock:clock)
        #expect(a.service.send(String(repeating: "Привет 👋 ", count: 50), to: b.card))
        drain([a,b]); b.service.tick(connected: [a.wire.myPeerID], active: true); drain([a,b])
        #expect(b.store.state.messages.count == 1)
        #expect(a.store.state.messages[0].status == .delivered)
        b.service.open(a.card); clock.date.addTimeInterval(31)
        b.service.tick(connected: [a.wire.myPeerID], active: true); drain([a,b])
        #expect(a.store.state.messages[0].status == .read)
        b.wire.myPeerID = PeerID(str: "abcdef0123456789")
        connect(a,b,clock:clock)
        #expect(a.service.send("Новая BLE-сессия", to: b.card)); drain([a,b])
        #expect(b.store.state.messages.count == 2)
        #expect(b.store.state.conversations.count == 1)
    }
    @Test func typingTrafficDoesNotDelayDirectMessagesOrReceipts() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock)
        try allowBoth(a, b, clock: clock)
        connect(a, b, clock: clock)
        b.service.open(a.card)
        // Repeated short drafts create start/stop controls, as in an active chat.
        for _ in 0..<45 {
            a.service.setTyping(true, for: b.card)
            a.service.setTyping(false, for: b.card)
            drain([a, b])
            clock.date.addTimeInterval(0.5)
        }
        #expect(a.service.send("После набора", to: b.card))
        drain([a, b])
        #expect(b.store.state.messages.last?.text == "После набора")
        #expect(a.store.state.messages.last?.status == .read)
        #expect(b.service.send("Ответ", to: a.card))
        drain([a, b])
        #expect(a.store.state.messages.last?.text == "Ответ")
        #expect(b.store.state.messages.last?.status == .delivered)
    }

    @Test func relayCannotReadCarriesAcrossRestartAndRemovesOnSignedACK() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".enc")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock), c = try Node("Курьер", clock: clock, url: url)
        try allowBoth(a, b, clock: clock)
        connect(a,c,clock:clock)
        #expect(a.service.send("Через курьера", to: b.card)); drain([a,c])
        #expect(c.store.state.messages.isEmpty)
        let copy = try #require(c.store.state.relay.first)
        #expect(throws: (any Error).self) { _ = try c.wire.openShumPayload(copy.envelope.ciphertext) }
        // A fresh coordinator consumes the persisted relay snapshot.
        c.store = try ShumConversationStore(ownerID: c.card.id, key: c.identity.storageKey, url: url)
        c.service = try ShumMessageStore(identity: c.identity, store: c.store, transport: c.wire, wire: c.wire, card: c.card, internet: nil, now: { clock.date })
        #expect(c.service.state.relay.count == 1)
        a.wire.connectedPeers = []; a.service.tick(connected: [], active: true)
        clock.date.addTimeInterval(31); connect(c,b,clock:clock)
        c.service.tick(connected: [b.wire.myPeerID], active: true); drain([c,b])
        b.service.tick(connected: [c.wire.myPeerID], active: true); drain([c,b])
        #expect(b.store.state.messages.first?.text == "Через курьера")
        #expect(c.store.state.relay.isEmpty)
        clock.date.addTimeInterval(31); connect(a,c,clock:clock)
        c.service.tick(connected: [a.wire.myPeerID], active: true); drain([a,c])
        #expect(a.store.state.messages[0].status == .delivered)
    }
    @Test func nostrAndBLEUseSameMessageDedupAndWrongACKCannotDeliver() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock), mallory = try Node("Другой", clock: clock)
        try allowBoth(a, b, clock: clock)
        #expect(a.service.send("Один диалог", to: b.card))
        let envelope = try #require(a.store.state.messages.first?.envelope)
        let packet = ShumPacket(envelope: envelope, hopCount: 1)
        let content = ShumWireProtocol.relayPrefix
            + (try ShumCoding.encode(packet)).base64EncodedString()
        let event = try NostrProtocol.createPrivateMessage(content: content, recipientPubkey: b.identity.nostr.publicKeyHex, senderIdentity: a.identity.nostr)
        let decoded = try NostrProtocol.decryptPrivateMessage(giftWrap: event, recipientIdentity: b.identity.nostr)
        #expect(decoded.content == content)
        b.service.receive(packet, from: nil, nostrSender: decoded.senderPubkey)
        b.service.receive(packet, from: nil, nostrSender: decoded.senderPubkey)
        #expect(b.store.state.messages.count == 1)
        var receipt = try #require(b.store.state.receipts.first?.receipt)
        receipt.sender = mallory.card
        receipt.signature = try #require(mallory.wire.noiseSignData(receipt.signingBytes()))
        a.service.receive(ShumPacket(receipt: receipt), from: nil, nostrSender: mallory.card.nostrKey)
        #expect(a.store.state.messages[0].status == .queued)
        receipt = try #require(b.store.state.receipts.first?.receipt)
        a.service.receive(ShumPacket(receipt: receipt), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.store.state.messages[0].status == .delivered)
    }
    @Test func expiryHopLimitTamperAndUnknownContactAreBounded() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock), c = try Node("Курьер", clock: clock)
        try allow(a, to: b, clock: clock); connect(a,c,clock:clock)
        #expect(a.service.send("Запрос контакта", to: b.card)); drain([a,c])
        let message = try #require(a.store.state.messages.first)
        b.service.receive(ShumPacket(envelope: message.envelope, hopCount: 1), from: nil, nostrSender: a.card.nostrKey)
        #expect(b.store.state.messages.isEmpty)
        #expect(b.store.state.requests.count == 1)
        var changed = message.envelope; changed.expiresAt += 86_400_000
        #expect(throws: (any Error).self) { try changed.validate(at: clock.date) }
        clock.date.addTimeInterval(86_401)
        a.service.tick(connected: [], active: true); c.service.tick(connected: [], active: true)
        #expect(a.store.state.messages[0].status == .expired)
        #expect(c.store.state.relay.isEmpty)
    }
    @Test func backgroundDeliveryDoesNotClaimReadAndHopLimitRejectsDeposit() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock), c = try Node("Курьер", clock: clock)
        try allowBoth(a, b, clock: clock)
        connect(a,b,clock:clock)
        b.service.open(a.card); b.service.setActive(false)
        #expect(a.service.send("В фоне", to: b.card)); drain([a,b])
        #expect(b.store.state.messages.first?.unread == true)
        #expect(a.store.state.messages.first?.status == .delivered)
        b.service.setActive(true); clock.date.addTimeInterval(31)
        b.service.tick(connected: [a.wire.myPeerID], active: true); drain([a,b])
        #expect(a.store.state.messages.first?.status == .read)
        connect(a,c,clock:clock)
        let envelope = try #require(a.store.state.messages.first?.envelope)
        c.service.receive(ShumPacket(envelope: envelope, hopCount: 4), from: a.wire.myPeerID, nostrSender: nil)
        #expect(c.store.state.relay.isEmpty)
        c.service.receive(ShumPacket(envelope: envelope, hopCount: 0), from: a.wire.myPeerID, nostrSender: nil)
        #expect(c.store.state.relay.isEmpty)
    }

    @Test func backgroundWakeExchangesCardsAndDrainsQueuedBluetoothMessage() throws {
        let clock = Clock()
        let a = try Node("Аня", clock: clock)
        let b = try Node("Борис", clock: clock)
        try allowBoth(a, b, clock: clock)

        a.service.setActive(false)
        b.service.setActive(false)
        #expect(a.service.send("Доставить в фоне", to: b.card))
        #expect(a.store.state.messages.first?.status == .queued)

        a.wire.connectedPeers = [b.wire.myPeerID]
        b.wire.connectedPeers = [a.wire.myPeerID]
        a.wire.shumSessionKeys[b.wire.myPeerID] = b.card.noiseKey
        b.wire.shumSessionKeys[a.wire.myPeerID] = a.card.noiseKey

        a.service.tick(connected: [b.wire.myPeerID], active: false)
        b.service.tick(connected: [a.wire.myPeerID], active: false)
        drain([a, b])
        a.service.tick(connected: [b.wire.myPeerID], active: false)
        drain([a, b])

        #expect(b.store.state.messages.first?.text == "Доставить в фоне")
        #expect(b.store.state.messages.first?.unread == true)
        #expect(a.store.state.messages.first?.status == .delivered)
    }
    @Test func failedDiskWriteNeverPublishesMemoryOrDeliveryACK() throws {
        let clock = Clock(), directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("state.enc")
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock, url: url)
        try allowBoth(a, b, clock: clock)
        connect(a,b,clock:clock)
        try FileManager.default.removeItem(at: directory)
        try Data([1]).write(to: directory) // Parent is now a file: force an actual failed atomic write.
        #expect(a.service.send("Не подтверждай до сохранения", to: b.card)); drain([a,b])
        #expect(b.store.state.messages.isEmpty)
        #expect(b.store.state.receipts.isEmpty)
        #expect(a.store.state.messages.first?.status == .forwarding)
    }

    @Test func blockingPersistsAndRejectsDirectNostrAndCourierMessages() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock), c = try Node("Курьер", clock: clock)
        try allowBoth(a, b, clock: clock)
        #expect(a.service.send("Не отправлять после блокировки", to: b.card))
        try a.service.setBlocked(b.card, blocked: true)
        #expect(a.store.state.messages.first?.status == .cancelled)
        #expect(!a.service.send("Запрещено", to: b.card))
        #expect(throws: (any Error).self) { try a.service.add(b.card, source: "QR") }
        #expect(b.service.send("Не принимать", to: a.card))
        let packet = ShumPacket(envelope: b.store.state.messages[0].envelope, hopCount: 1)
        connect(a,b,clock:clock)
        a.service.receive(packet, from: b.wire.myPeerID, nostrSender: nil)
        a.service.receive(packet, from: nil, nostrSender: b.card.nostrKey)
        connect(a,c,clock:clock)
        a.service.receive(packet, from: c.wire.myPeerID, nostrSender: nil)
        #expect(a.store.state.messages.count == 1)
        #expect(a.store.state.requests.isEmpty)
        let decoded = try JSONDecoder().decode(ShumDatabase.self, from: ShumCoding.encode(a.store.state))
        #expect(decoded.blocked?[b.card.id] != nil)
        try a.service.setBlocked(b.card, blocked: false)
        a.service.receive(packet, from: nil, nostrSender: b.card.nostrKey)
        #expect(a.store.state.messages.count == 2)
        #expect(a.store.state.messages.first?.status == .cancelled)
    }
    @Test func deletingHistoryStopsOutboxAndPreventsReplayButAllowsNewMessages() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock)
        try allowBoth(a, b, clock: clock)
        #expect(b.service.send("Старая история", to: a.card))
        let packet = ShumPacket(envelope: b.store.state.messages[0].envelope, hopCount: 1)
        a.service.receive(packet, from: nil, nostrSender: b.card.nostrKey)
        #expect(a.service.send("Старая очередь", to: b.card))
        try a.service.deleteConversation(with: b.card)
        #expect(a.store.state.messages.isEmpty)
        #expect(a.store.state.conversations.isEmpty)
        #expect(a.store.state.contacts.count == 1)
        a.service.receive(packet, from: nil, nostrSender: b.card.nostrKey)
        #expect(a.store.state.messages.isEmpty)
        // A new ID must be accepted even within the same timestamp, or when
        // the sender's clock is slightly behind. Do not use a time cutoff.
        #expect(b.service.send("Новый разговор", to: a.card))
        a.service.receive(ShumPacket(envelope: b.store.state.messages[1].envelope, hopCount: 1), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.store.state.messages.count == 1)
        try a.service.deleteConversation(with: b.card, removeContact: true)
        #expect(a.store.state.contacts.isEmpty)
        #expect(a.store.state.messages.isEmpty)
        #expect(a.store.state.receipts.isEmpty)
    }

    @Test func removingFromContactsPreservesChatAndMessagingAccess() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock)
        try allowBoth(a, b, clock: clock)
        #expect(a.service.send("История", to: b.card))

        try a.service.removeFromContacts(b.card)

        #expect(!a.service.isAddressBookContact(b.card))
        #expect(a.store.state.contacts.count == 1)
        #expect(a.store.state.messages.count == 1)
        #expect(a.store.state.conversations.count == 1)
        #expect(!a.service.isBlocked(b.card))
        #expect(a.service.invitationPhase(for: b.card) == .accepted)
        #expect(a.service.send("Общение сохранено", to: b.card))

        try a.service.add(b.card, source: "chat-menu")
        #expect(a.service.isAddressBookContact(b.card))
    }
    @Test func addingAnInvitationSenderToContactsDoesNotAcceptTheInvitation() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock)
        connect(a, b, clock: clock)

        #expect(a.service.sendInvitation(b.card))
        drain([a, b])
        #expect(!a.service.isAddressBookContact(b.card))
        #expect(!b.service.isAddressBookContact(a.card))
        #expect(b.service.invitationPhase(for: a.card) == .incomingPending)

        try b.service.add(a.card, source: "conversation")

        #expect(b.service.isAddressBookContact(a.card))
        #expect(b.service.invitationPhase(for: a.card) == .incomingPending)
        #expect(b.store.state.requests.contains { $0.id == a.card.id })

        #expect(b.service.acceptInvitation(a.card))
        drain([a, b])
        #expect(!a.service.isAddressBookContact(b.card))
        #expect(b.service.isAddressBookContact(a.card))
        #expect(a.service.invitationPhase(for: b.card) == .accepted)
        #expect(b.service.invitationPhase(for: a.card) == .accepted)
    }
    @Test func clearingChatPreservesAcceptanceAndRepairsPreviouslyResetPeer() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock)
        try allowBoth(a, b, clock: clock)
        connect(a, b, clock: clock)

        #expect(a.service.send("Локальная история", to: b.card))
        drain([a, b])
        a.wire.shumPackets.removeAll()
        b.wire.shumPackets.removeAll()

        try a.service.clearDirectoryEntry(b.card)

        #expect(a.store.state.messages.isEmpty)
        #expect(a.store.state.conversations.isEmpty)
        #expect(a.store.state.contacts.contains { $0.id == b.card.id })
        #expect(a.service.invitationPhase(for: b.card) == .accepted)
        #expect(a.wire.shumPackets.isEmpty)
        #expect(b.wire.shumPackets.isEmpty)

        #expect(b.service.send("Новый разговор", to: a.card))
        drain([a, b])
        #expect(a.store.state.messages.last?.text == "Новый разговор")

        // Repair the state left by the old clear implementation: one side
        // forgot the acceptance while the other side retained it.
        try a.store.transaction { state in
            state.invitationStates?.removeValue(forKey: b.card.id)
        }
        #expect(a.service.invitationPhase(for: b.card) == .ready)
        clock.date.addTimeInterval(1)
        #expect(a.service.sendInvitation(b.card))
        drain([a, b])
        #expect(a.service.invitationPhase(for: b.card) == .accepted)
        #expect(b.service.invitationPhase(for: a.card) == .accepted)
        #expect(b.store.state.requests.isEmpty)
    }
    @Test func oldDatabaseMigratesAndRetiredCoordinatorCannotReviveData() throws {
        let clock = Clock(), a = try Node("Аня", clock: clock), b = try Node("Борис", clock: clock)
        try a.service.add(b.card, source: "QR")
        let data = try ShumCoding.encode(a.store.state)
        let migrated = try JSONDecoder().decode(ShumDatabase.self, from: data)
        #expect(migrated.blocked == nil && migrated.deletedMessageIDs == nil)
        a.service.retire(); a.service.setActive(true); connect(a,b,clock:clock)
        #expect(!a.service.send("После удаления", to: b.card))
        a.service.receive(ShumPacket(card: b.card), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.store.state.requests.isEmpty)
        #expect(a.wire.shumPackets.isEmpty)
    }

}
