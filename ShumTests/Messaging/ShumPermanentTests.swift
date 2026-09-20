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
            service = ShumMessageStore(identity: identity, store: store, transport: wire, wire: wire, card: card, internet: nil, now: { clock.date })
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
        guard case let .locator(locator) = compactInvitation else {
            Issue.record("The compact invitation must contain a Nostr locator")
            return
        }
        #expect(locator.nostrKey == a.card.nostrKey)
        #expect(try ShumContactCard.parse(a.card.legacyInvitation()) == a.card)
        var tampered = a.card; tampered.nostrKey = String(repeating: "0", count: 64)
        #expect(throws: (any Error).self) { try tampered.validate() }
        a.wire.mockKeychain.simulatedReadError = .deviceLocked
        #expect(throws: (any Error).self) { _ = try ShumIdentityService(transport: a.wire, keychain: a.wire.mockKeychain, bridge: NostrIdentityBridge(keychain: a.wire.mockKeychain)) }
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
        c.service = ShumMessageStore(identity: c.identity, store: c.store, transport: c.wire, wire: c.wire, card: c.card, internet: nil, now: { clock.date })
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
