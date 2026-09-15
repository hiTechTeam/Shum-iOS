import BitFoundation
import Combine
import Foundation

/// Application-level outbox/relay coordinator. It never controls CoreBluetooth.
/// All message crypto and link writes delegate to the existing bitchat stack.
@MainActor
final class SpotchatMessageStore: ObservableObject {
    static let encounterRetention: TimeInterval = 24 * 60 * 60
    static let invitationLifetimeMilliseconds: Int64 = 30 * 86_400_000
    @Published private(set) var revision = 0
    let store: SpotchatConversationStore
    let contacts: SpotchatContactsService
    private let identity: SpotchatIdentityService
    private let crypto: SpotchatCryptoService
    private let transport: Transport
    private let wire: SpotchatSecureTransport
    private let internet: SpotchatNostrService?
    private let now: () -> Date
    var ownCard: SpotchatContactCard
    var onError: ((String) -> Void)?
    private(set) var nearby: [PeerID: SpotchatContactCard] = [:]
    private var helloTimes: [PeerID: Date] = [:]
    private var ingressRate: [String: (Date, Int)] = [:]
    private var activeContact: String?
    private var foreground = true
    private var tickNumber = 0
    private var localSessionID: PeerID?
    private var retired = false

    init(identity: SpotchatIdentityService, store: SpotchatConversationStore, transport: Transport,
         wire: SpotchatSecureTransport, card: SpotchatContactCard,
         internet: SpotchatNostrService?, now: @escaping () -> Date = Date.init) {
        self.identity = identity; self.store = store; self.transport = transport; self.wire = wire
        self.crypto = SpotchatCryptoService(wire: wire); self.ownCard = card
        self.contacts = SpotchatContactsService(store: store); self.internet = internet; self.now = now
        internet?.received = { [weak self] packet, sender in self?.receive(packet, from: nil, nostrSender: sender) }
    }
    var internetConnected: Bool { internet?.connected == true }
    var state: SpotchatDatabase { store.state }

    func configureContactLookup(profile: @escaping () -> SpotchatProfile?) {
        internet?.configureContactLookup(
            card: { [weak self] in self?.ownCard },
            profile: profile
        )
    }

    func resolve(_ locator: SpotchatContactLocator, completion: @escaping (Result<SpotchatResolvedContact, Error>) -> Void) {
        guard let internet else {
            completion(.failure(SpotchatFailure.contactUnavailable))
            return
        }
        internet.resolve(locator, completion: completion)
    }

    var encounterHistory: [SpotchatEncounter] {
        (state.encounters ?? [])
            .filter {
                !isBlocked($0.card)
                    && $0.lastSeen >= now().addingTimeInterval(-Self.encounterRetention)
            }
            .sorted { $0.lastSeen > $1.lastSeen }
    }
    var savedProfiles: [SpotchatSavedProfile] {
        (state.savedProfiles ?? [])
            .filter { !isBlocked($0.card) }
            .sorted { $0.savedAt > $1.savedAt }
    }
    var unviewedEncounterCount: Int {
        let visibleIDs = Set(encounterHistory.map(\.id))
        return (state.unviewedEncounterIDs ?? []).intersection(visibleIDs).count
    }
    var unviewedEncounterIDs: Set<String> {
        let visibleIDs = Set(encounterHistory.map(\.id))
        return (state.unviewedEncounterIDs ?? []).intersection(visibleIDs)
    }
    func start() { if !retired && foreground { internet?.start() } }
    func setActive(_ active: Bool) {
        guard !retired else { return }
        foreground = active
        if active { internet?.start(); markRead() }
        else { internet?.stop() }
    }
    func updateProfile(name: String, bio: String) throws {
        ownCard = try identity.card(name: name, bio: bio); helloTimes.removeAll()
    }
    func card(for peer: PeerID) -> SpotchatContactCard? {
        state.contacts.first(where: { $0.card.peerID == peer })?.card
            ?? nearby[peer]
            ?? state.savedProfiles?.first(where: { $0.card.peerID == peer })?.card
            ?? state.encounters?.first(where: { $0.card.peerID == peer })?.card
            ?? state.requests.first(where: { $0.peerID == peer })
            ?? state.blocked?.values.first(where: { $0.peerID == peer })
    }
    func session(for card: SpotchatContactCard) -> PeerID? {
        nearby.first(where: { $0.value.id == card.id && transport.isPeerConnected($0.key) && transport.noiseSessionPublicKeyData(for: $0.key) == card.noiseKey })?.key
    }
    func add(_ card: SpotchatContactCard, source: String, avatar: Data? = nil) throws {
        guard !retired else { throw SpotchatFailure.unavailableIdentity }
        guard !isBlocked(card) else { throw SpotchatFailure.blocked }
        let acceptsIncomingInvitation = state.requests.contains { $0.id == card.id }
        try contacts.add(card, source: source, avatar: avatar, now: now())
        try contacts.conversation(with: card, now: now())
        if acceptsIncomingInvitation {
            try transitionInvitation(with: card, action: .accept, phase: .accepted, removesRequest: true)
        } else {
            try store.transaction { state in
                if state.invitationStates == nil { state.invitationStates = [:] }
                if state.invitationStates?[card.id] == nil {
                    state.invitationStates?[card.id] = SpotchatInvitationState(
                        phase: source == "preview" ? .accepted : .ready,
                        updatedAt: Int64(now().timeIntervalSince1970 * 1000),
                        eventID: UUID().uuidString
                    )
                }
            }
            changed()
        }
    }
    func dismissRequest(_ card: SpotchatContactCard) {
        _ = declineInvitation(card)
    }
    func invitationPhase(for card: SpotchatContactCard) -> SpotchatInvitationPhase {
        if let phase = state.invitationStates?[card.id]?.phase { return phase }
        if state.requests.contains(where: { $0.id == card.id }) { return .incomingPending }
        return .ready
    }
    func canMessage(_ card: SpotchatContactCard) -> Bool {
        invitationPhase(for: card) == .accepted
    }
    @discardableResult
    func sendInvitation(_ card: SpotchatContactCard) -> Bool {
        guard !retired, !isBlocked(card), invitationPhase(for: card) == .ready else { return false }
        do {
            try contacts.add(card, source: "chat-invitation", now: now())
            try contacts.conversation(with: card, now: now())
            try transitionInvitation(with: card, action: .request, phase: .outgoingPending)
            return true
        } catch { fail(error); return false }
    }
    @discardableResult
    func acceptInvitation(_ card: SpotchatContactCard) -> Bool {
        let phase = invitationPhase(for: card)
        guard !retired, !isBlocked(card), phase == .incomingPending || phase == .declinedLocally else { return false }
        do {
            try contacts.add(card, source: "accepted-invitation", now: now())
            try contacts.conversation(with: card, now: now())
            try transitionInvitation(with: card, action: .accept, phase: .accepted, removesRequest: true)
            return true
        } catch { fail(error); return false }
    }
    @discardableResult
    func declineInvitation(_ card: SpotchatContactCard) -> Bool {
        guard !retired, !isBlocked(card), invitationPhase(for: card) == .incomingPending else { return false }
        do {
            try transitionInvitation(with: card, action: .decline, phase: .declinedLocally)
            return true
        } catch { fail(error); return false }
    }

    private func transitionInvitation(
        with card: SpotchatContactCard,
        action: SpotchatInvitationAction,
        phase: SpotchatInvitationPhase,
        removesRequest: Bool = false
    ) throws {
        let previousTimestamp = state.invitationStates?[card.id]?.updatedAt ?? 0
        let timestamp = max(
            Int64(now().timeIntervalSince1970 * 1000),
            previousTimestamp + 1
        )
        var control = SpotchatInvitationControl(
            id: UUID().uuidString,
            sender: ownCard,
            recipient: card,
            action: action,
            timestamp: timestamp,
            expiresAt: timestamp + Self.invitationLifetimeMilliseconds
        )
        guard let signature = transport.noiseSignData(try control.signingBytes()) else {
            throw SpotchatFailure.unavailableIdentity
        }
        control.signature = signature
        try store.transaction { state in
            if state.invitationStates == nil { state.invitationStates = [:] }
            if state.invitationOutbox == nil { state.invitationOutbox = [] }
            state.invitationStates?[card.id] = SpotchatInvitationState(
                phase: phase,
                updatedAt: timestamp,
                eventID: control.id
            )
            state.invitationOutbox?.removeAll {
                $0.control.recipient.id == card.id
            }
            state.invitationOutbox?.append(
                SpotchatStoredInvitationControl(control: control)
            )
            if removesRequest {
                state.requests.removeAll { $0.id == card.id }
            }
        }
        changed()
        routeInvitationControls()

        // Older Shum builds use a signed card as their request/acceptance
        // signal. Keep that Nostr compatibility while the new signed control
        // is the source of truth for current builds.
        if action == .request {
            internet?.send(SpotchatPacket(card: ownCard), to: card) { _ in }
        } else if action == .accept {
            if let peer = session(for: card) {
                sendPacket(SpotchatPacket(card: ownCard), to: peer)
            }
            internet?.send(SpotchatPacket(card: ownCard), to: card) { _ in }
        }
    }

    private func receiveInvitation(_ control: SpotchatInvitationControl) throws {
        try control.validate(at: now())
        guard control.recipient.noiseKey == ownCard.noiseKey,
              control.recipient.signingKey == ownCard.signingKey,
              control.recipient.nostrKey == ownCard.nostrKey,
              control.sender.id != ownCard.id else {
            throw SpotchatFailure.invalidMessage
        }

        if state.invitationStates?[control.sender.id]?.eventID == control.id {
            return
        }
        let currentPhase = invitationPhase(for: control.sender)
        let hasOutgoingRequest = (state.invitationOutbox ?? []).contains {
            $0.control.recipient.id == control.sender.id
                && $0.control.action == .request
        }
        switch control.action {
        case .request:
            guard currentPhase == .ready
                    || currentPhase == .outgoingPending
                    || currentPhase == .declinedByPeer else { return }
            try store.transaction { state in
                if let index = state.requests.firstIndex(where: { $0.id == control.sender.id }) {
                    state.requests[index] = control.sender
                } else {
                    guard state.requests.count < 20 else { throw SpotchatFailure.quota }
                    state.requests.append(control.sender)
                }
                if state.invitationStates == nil { state.invitationStates = [:] }
                state.invitationStates?[control.sender.id] = SpotchatInvitationState(
                    phase: .incomingPending,
                    updatedAt: control.timestamp,
                    eventID: control.id
                )
            }
        case .accept:
            guard currentPhase == .outgoingPending
                    || currentPhase == .declinedByPeer
                    || currentPhase == .accepted
                    || (currentPhase == .incomingPending && hasOutgoingRequest) else { return }
            try contacts.add(control.sender, source: "invitation-accepted", now: now())
            try contacts.conversation(with: control.sender, now: now())
            try store.transaction { state in
                if state.invitationStates == nil { state.invitationStates = [:] }
                state.invitationStates?[control.sender.id] = SpotchatInvitationState(
                    phase: .accepted,
                    updatedAt: control.timestamp,
                    eventID: control.id
                )
                state.requests.removeAll { $0.id == control.sender.id }
                state.invitationOutbox?.removeAll {
                    $0.control.recipient.id == control.sender.id
                        && $0.control.action == .request
                }
            }
        case .decline:
            guard currentPhase == .outgoingPending
                    || currentPhase == .declinedByPeer
                    || (currentPhase == .incomingPending && hasOutgoingRequest) else { return }
            try store.transaction { state in
                if state.invitationStates == nil { state.invitationStates = [:] }
                state.invitationStates?[control.sender.id] = SpotchatInvitationState(
                    phase: .declinedByPeer,
                    updatedAt: control.timestamp,
                    eventID: control.id
                )
                state.requests.removeAll { $0.id == control.sender.id }
                state.invitationOutbox?.removeAll {
                    $0.control.recipient.id == control.sender.id
                        && $0.control.action == .request
                }
            }
        }
        changed()
    }
    func open(_ card: SpotchatContactCard?) {
        guard !retired else { return }
        activeContact = card?.id
        if let card { do { try contacts.conversation(with: card, now: now()); changed() } catch { fail(error) } }
        markRead()
    }
    func updateAvatar(_ avatar: Data?, for peer: PeerID) {
        guard !retired else { return }
        guard (avatar?.count ?? 0) <= 40_960, let card = nearby[peer] else { return }
        let contactNeedsUpdate = state.contacts.first(where: { $0.id == card.id })?.avatar != avatar
        let encounterNeedsUpdate = state.encounters?.first(where: { $0.id == card.id })?.avatar != avatar
        let savedNeedsUpdate = state.savedProfiles?.first(where: { $0.id == card.id })?.avatar != avatar
        guard contactNeedsUpdate || encounterNeedsUpdate || savedNeedsUpdate else { return }
        do {
            try store.transaction { state in
                if let index = state.contacts.firstIndex(where: { $0.id == card.id }) {
                    state.contacts[index].avatar = avatar
                }
                if let index = state.encounters?.firstIndex(where: { $0.id == card.id }) {
                    state.encounters?[index].avatar = avatar
                }
                if let index = state.savedProfiles?.firstIndex(where: { $0.id == card.id }) {
                    state.savedProfiles?[index].avatar = avatar
                }
            }
            changed()
        } catch { fail(error) }
    }

    func recordEncounter(_ card: SpotchatContactCard, avatar: Data? = nil) throws {
        guard !retired else { throw SpotchatFailure.unavailableIdentity }
        try card.validate()
        guard card.id != ownCard.id, !isBlocked(card), (avatar?.count ?? 0) <= 40_960 else { return }
        let timestamp = now()
        if let existing = state.encounters?.first(where: { $0.id == card.id }),
           timestamp.timeIntervalSince(existing.lastSeen) < 60,
           existing.card == card,
           avatar == nil || existing.avatar == avatar {
            return
        }
        try store.transaction { state in
            if state.encounters == nil { state.encounters = [] }
            if state.unviewedEncounterIDs == nil { state.unviewedEncounterIDs = [] }
            if let index = state.encounters?.firstIndex(where: { $0.id == card.id }) {
                guard state.encounters?[index].card.signingKey == card.signingKey,
                      state.encounters?[index].card.nostrKey == card.nostrKey else {
                    throw SpotchatFailure.invalidContact
                }
                let previous = state.encounters?[index].lastSeen ?? timestamp
                let isNewForCurrentHistory = timestamp.timeIntervalSince(previous)
                    >= Self.encounterRetention
                state.encounters?[index].card = card
                state.encounters?[index].lastSeen = timestamp
                if timestamp.timeIntervalSince(previous) >= 60 {
                    state.encounters?[index].seenCount += 1
                }
                if let avatar { state.encounters?[index].avatar = avatar }
                if isNewForCurrentHistory {
                    state.unviewedEncounterIDs?.insert(card.id)
                }
            } else {
                state.encounters?.append(
                    SpotchatEncounter(
                        card: card,
                        firstSeen: timestamp,
                        lastSeen: timestamp,
                        seenCount: 1,
                        avatar: avatar
                    )
                )
                state.unviewedEncounterIDs?.insert(card.id)
                if let count = state.encounters?.count, count > 1_000 {
                    let savedIDs = Set((state.savedProfiles ?? []).map(\.id))
                    state.encounters = state.encounters?
                        .sorted { $0.lastSeen > $1.lastSeen }
                        .enumerated()
                        .filter { $0.offset < 1_000 || savedIDs.contains($0.element.id) }
                        .map(\.element)
                }
            }
            if let index = state.savedProfiles?.firstIndex(where: { $0.id == card.id }) {
                guard state.savedProfiles?[index].card.signingKey == card.signingKey,
                      state.savedProfiles?[index].card.nostrKey == card.nostrKey else {
                    throw SpotchatFailure.invalidContact
                }
                state.savedProfiles?[index].card = card
                if let avatar { state.savedProfiles?[index].avatar = avatar }
            }
        }
        changed()
    }

    @discardableResult
    func toggleSaved(_ card: SpotchatContactCard, avatar: Data? = nil) throws -> Bool {
        guard !retired else { throw SpotchatFailure.unavailableIdentity }
        try card.validate()
        guard card.id != ownCard.id, !isBlocked(card), (avatar?.count ?? 0) <= 40_960 else {
            throw SpotchatFailure.invalidContact
        }
        var isSaved = false
        try store.transaction { state in
            if state.savedProfiles == nil { state.savedProfiles = [] }
            if let index = state.savedProfiles?.firstIndex(where: { $0.id == card.id }) {
                state.savedProfiles?.remove(at: index)
            } else {
                guard (state.savedProfiles?.count ?? 0) < 2_000 else { throw SpotchatFailure.quota }
                state.savedProfiles?.append(
                    SpotchatSavedProfile(card: card, savedAt: now(), avatar: avatar)
                )
                isSaved = true
            }
        }
        changed()
        return isSaved
    }

    func isSaved(_ card: SpotchatContactCard) -> Bool {
        state.savedProfiles?.contains(where: { $0.id == card.id }) == true
    }

    func markEncountersViewed() {
        guard !retired, !(state.unviewedEncounterIDs ?? []).isEmpty else { return }
        do {
            try store.transaction { $0.unviewedEncounterIDs = [] }
            changed()
        } catch { fail(error) }
    }

    func markEncounterViewed(_ id: String) {
        guard !retired,
              state.unviewedEncounterIDs?.contains(id) == true else { return }
        do {
            try store.transaction { $0.unviewedEncounterIDs?.remove(id) }
            changed()
        } catch { fail(error) }
    }

    func deleteEncounter(_ card: SpotchatContactCard) {
        guard !retired, state.encounters?.contains(where: { $0.id == card.id }) == true else { return }
        do {
            try store.transaction { state in
                state.encounters?.removeAll { $0.id == card.id }
                state.unviewedEncounterIDs?.remove(card.id)
            }
            changed()
        } catch { fail(error) }
    }

    func clearEncounters() {
        guard !retired, !(state.encounters ?? []).isEmpty else { return }
        do {
            try store.transaction { state in
                state.encounters = []
                state.unviewedEncounterIDs = []
            }
            changed()
        } catch { fail(error) }
    }
    @discardableResult
    func send(_ text: String, to card: SpotchatContactCard) -> Bool {
        guard !retired else { return false }
        guard !isBlocked(card) else { fail(SpotchatFailure.blocked); return false }
        guard canMessage(card) else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4096 else { onError?("Сообщение должно быть не длиннее 4096 байт."); return false }
        do {
            if !state.contacts.contains(where: { $0.id == card.id }) {
                throw SpotchatFailure.invalidContact
            }
            guard state.messages.filter({ $0.outgoing && [.queued, .forwarding].contains($0.status) }).count < 200 else { throw SpotchatFailure.quota }
            let id = UUID().uuidString, timestamp = Int64(now().timeIntervalSince1970 * 1000)
            let conversation = SpotchatConversation.identifier(ownCard.id, card.id)
            let payload = SpotchatPlaintext(id: id, conversationID: conversation, senderID: ownCard.id, recipientID: card.id,
                                           timestamp: timestamp, expiresAt: timestamp + 86_400_000, text: text)
            var envelope = SpotchatEnvelope(id: id, conversationID: conversation, sender: ownCard, recipient: card,
                timestamp: timestamp, expiresAt: payload.expiresAt, ciphertext: try crypto.seal(SpotchatCoding.encode(payload), to: card.noiseKey))
            guard let signature = transport.noiseSignData(try envelope.signingBytes()) else { throw SpotchatFailure.unavailableIdentity }
            envelope.signature = signature
            try contacts.conversation(with: card, now: now())
            try store.transaction { $0.messages.append(SpotchatStoredMessage(envelope: envelope, text: text, outgoing: true, status: .queued)) }
            changed(); routeOutbox(); return true
        } catch { fail(error); return false }
    }
    func tick(connected: Set<PeerID>, active: Bool) {
        guard !retired else { return }
        tickNumber += 1
        if localSessionID != transport.myPeerID {
            localSessionID = transport.myPeerID
            helloTimes.removeAll()
        }
        nearby = nearby.filter { connected.contains($0.key) }
        helloTimes = helloTimes.filter { connected.contains($0.key) }
        if tickNumber % 30 == 0 { ingressRate = ingressRate.filter { now().timeIntervalSince($0.value.0) < 60 } }
        guard active else { return }
        for peer in connected.sorted(by: { $0.id < $1.id }).prefix(20) where now().timeIntervalSince(helloTimes[peer] ?? .distantPast) >= 30 {
            helloTimes[peer] = now(); sendPacket(SpotchatPacket(card: ownCard), to: peer)
        }
        do {
            let ms = Int64(now().timeIntervalSince1970 * 1000)
            if state.relay.contains(where: { $0.envelope.expiresAt <= ms }) || state.receipts.contains(where: { $0.receipt.expiresAt <= ms }) || state.messages.contains(where: { $0.outgoing && [.queued, .forwarding].contains($0.status) && $0.envelope.expiresAt <= ms }) || (state.invitationOutbox ?? []).contains(where: { $0.control.expiresAt <= ms || $0.nostrAccepted || ($0.control.action != .request && $0.attempts >= 6) }) || (tickNumber % 30 == 0 && (!state.seenRelay.isEmpty || !(state.deletedMessageIDs ?? [:]).isEmpty)) {
                try store.transaction { state in
                    state.relay.removeAll { $0.envelope.expiresAt <= ms }
                    state.receipts.removeAll { $0.receipt.expiresAt <= ms }
                    state.invitationOutbox?.removeAll {
                        $0.control.expiresAt <= ms
                            || $0.nostrAccepted
                            || ($0.control.action != .request && $0.attempts >= 6)
                    }
                    state.seenRelay = state.seenRelay.filter { $0.value > now() }
                    state.deletedMessageIDs = state.deletedMessageIDs?.filter { $0.value > now() }
                    for i in state.messages.indices where state.messages[i].outgoing && [.queued, .forwarding].contains(state.messages[i].status) && state.messages[i].envelope.expiresAt <= ms { state.messages[i].status = .expired }
                }; changed()
            }
        } catch { fail(error); return }
        routeInvitationControls(); routeOutbox(); routeRelay(); routeReceipts(); markRead()
    }
    func receiveBytes(_ data: Data, from peer: PeerID) {
        guard data.count <= 24_000, let packet = try? JSONDecoder().decode(SpotchatPacket.self, from: data) else { return }
        receive(packet, from: peer, nostrSender: nil)
    }
    func receive(_ packet: SpotchatPacket, from peer: PeerID?, nostrSender: String?) {
        guard !retired else { return }
        if let peer, let key = transport.noiseSessionPublicKeyData(for: peer), state.blocked?[SpotchatContactCard.userID(key)] != nil { return }
        if let nostrSender, state.blocked?.values.contains(where: { $0.nostrKey == nostrSender }) == true { return }
        if let card = packet.card, isBlocked(card) { return }
        if let envelope = packet.envelope, isBlocked(envelope.sender) || isBlocked(envelope.recipient) { return }
        if let receipt = packet.receipt, isBlocked(receipt.sender) || isBlocked(receipt.destination) { return }
        if let invitation = packet.invitation,
           isBlocked(invitation.sender) || isBlocked(invitation.recipient) { return }
        let source = peer?.id ?? nostrSender ?? "unknown"
        let old = ingressRate[source] ?? (now(), 0)
        let progress = now().timeIntervalSince(old.0) >= 60 ? (now(), 0) : old
        guard progress.1 < 80, ingressRate.count < 1000 || ingressRate[source] != nil,
              packet.version == 1,
              [packet.card != nil, packet.envelope != nil, packet.receipt != nil, packet.invitation != nil]
                .filter({ $0 }).count == 1 else { return }
        ingressRate[source] = (progress.0, progress.1 + 1)
        do {
            if let card = packet.card {
                try card.validate()
                guard card.id != ownCard.id else { return }
                if let peer {
                    guard transport.noiseSessionPublicKeyData(for: peer) == card.noiseKey else { return }
                    let first = nearby[peer] == nil; nearby[peer] = card
                    if first { sendPacket(SpotchatPacket(card: ownCard), to: peer) }
                    try recordEncounter(card)
                    if state.contacts.contains(where: { $0.id == card.id }) { try contacts.add(card, source: "nearby", now: now()) }
                    changed()
                } else if nostrSender == card.nostrKey { try request(card) }
            } else if let envelope = packet.envelope {
                try envelope.validate(at: now())
                if let nostrSender, nostrSender != envelope.sender.nostrKey { return }
                if envelope.recipient.id == ownCard.id {
                    try accept(envelope, via: peer, hop: packet.hopCount ?? 0, internet: nostrSender != nil)
                } else if let peer, let depositor = nearby[peer],
                          transport.noiseSessionPublicKeyData(for: peer) == depositor.noiseKey {
                    try carry(envelope, hop: packet.hopCount ?? -1, depositor: depositor)
                }
            } else if let receipt = packet.receipt {
                if let nostrSender, nostrSender != receipt.sender.nostrKey { return }
                try acceptReceipt(receipt)
            } else if let invitation = packet.invitation {
                if let peer {
                    guard transport.noiseSessionPublicKeyData(for: peer) == invitation.sender.noiseKey else { return }
                }
                if let nostrSender, nostrSender != invitation.sender.nostrKey { return }
                try receiveInvitation(invitation)
            }
        } catch { /* Untrusted invalid packets do not produce modal alerts. */ }
    }
    private func request(_ card: SpotchatContactCard) throws {
        guard invitationPhase(for: card) != .accepted,
              invitationPhase(for: card) != .declinedLocally else { return }
        guard !state.requests.contains(where: { $0.id == card.id }), state.requests.count < 20 else { return }
        let timestamp = Int64(now().timeIntervalSince1970 * 1000)
        try store.transaction { state in
            state.requests.append(card)
            if state.invitationStates == nil { state.invitationStates = [:] }
            state.invitationStates?[card.id] = SpotchatInvitationState(
                phase: .incomingPending,
                updatedAt: timestamp,
                eventID: "legacy-\(UUID().uuidString)"
            )
        }
        changed()
    }
    private func accept(_ envelope: SpotchatEnvelope, via peer: PeerID?, hop: Int, internet: Bool) throws {
        guard internet || (1...envelope.hopLimit).contains(hop) else { throw SpotchatFailure.invalidMessage }
        if state.deletedMessageIDs?[envelope.id] != nil { return }
        guard envelope.recipient.noiseKey == ownCard.noiseKey,
              envelope.recipient.signingKey == ownCard.signingKey,
              envelope.recipient.nostrKey == ownCard.nostrKey else { throw SpotchatFailure.invalidMessage }
        let opened = try crypto.open(envelope.ciphertext)
        guard opened.senderStaticKey == envelope.sender.noiseKey else { throw SpotchatFailure.invalidMessage }
        let plain = try JSONDecoder().decode(SpotchatPlaintext.self, from: opened.payload)
        guard plain.protocolName == "spotchat.message.v1", plain.id == envelope.id,
              plain.conversationID == envelope.conversationID, plain.senderID == envelope.sender.id,
              plain.recipientID == ownCard.id, plain.timestamp == envelope.timestamp,
              plain.expiresAt == envelope.expiresAt, !plain.text.isEmpty, plain.text.utf8.count <= 4096 else { throw SpotchatFailure.invalidMessage }
        guard let contact = state.contacts.first(where: { $0.id == envelope.sender.id }) else {
            try request(envelope.sender); return
        }
        guard contact.card.signingKey == envelope.sender.signingKey, contact.card.nostrKey == envelope.sender.nostrKey else { throw SpotchatFailure.invalidContact }
        guard canMessage(contact.card) else { return }
        if let existing = state.messages.first(where: { $0.id == envelope.id }) {
            guard !existing.outgoing, existing.envelope.digest == envelope.digest else { throw SpotchatFailure.invalidMessage }
            try makeReceipt(for: existing, read: !existing.unread, force: true); return
        }
        try contacts.conversation(with: contact.card, now: now())
        let visible = foreground && activeContact == contact.id
        let message = SpotchatStoredMessage(envelope: envelope, text: plain.text, outgoing: false, status: .delivered, unread: !visible, hopCount: internet ? 0 : hop, deliveryTransport: internet ? "nostr" : (hop > 1 ? "mesh" : "ble"))
        try store.transaction { $0.messages.append(message) }; changed()
        try makeReceipt(for: message, read: visible, force: true)
        // Use an already executing Bluetooth background callback to return the
        // durable delivery ACK immediately; never mark background receipt read.
        if let peer, let receipt = state.receipts.first(where: { $0.receipt.envelopeID == message.id })?.receipt {
            sendPacket(SpotchatPacket(receipt: receipt), to: peer)
        }
    }
    private func carry(_ envelope: SpotchatEnvelope, hop: Int, depositor: SpotchatContactCard) throws {
        guard (1..<envelope.hopLimit).contains(hop), !state.seenRelay.keys.contains(envelope.id),
              state.relay.count < 64, state.seenRelay.count < 4000,
              state.relay.filter({ $0.depositor == depositor.id }).count < 8,
              !state.receipts.contains(where: { $0.receipt.envelopeID == envelope.id && $0.receipt.digest == envelope.digest && $0.receipt.sender.id == envelope.recipient.id }) else { return }
        try store.transaction {
            $0.relay.append(SpotchatRelayCopy(envelope: envelope, hopCount: hop, depositor: depositor.id, forwardedTo: [depositor.id]))
            $0.seenRelay[envelope.id] = Date(timeIntervalSince1970: Double(envelope.expiresAt) / 1000)
        }; changed()
    }
    private func makeReceipt(for message: SpotchatStoredMessage, read: Bool, force: Bool = false) throws {
        if let existing = state.receipts.first(where: { $0.receipt.envelopeID == message.id && $0.receipt.digest == message.envelope.digest }), existing.receipt.read == read || existing.receipt.read {
            if force, now().timeIntervalSince(existing.lastAttempt) > 10 {
                try store.transaction { state in
                    if let i = state.receipts.firstIndex(where: { $0.receipt.key == existing.receipt.key }) { state.receipts[i].lastAttempt = .distantPast; state.receipts[i].sentTo.removeAll(); state.receipts[i].nostrAccepted = false }
                }
            }
            return
        }
        guard message.envelope.expiresAt > Int64(now().timeIntervalSince1970 * 1000) else { return }
        var receipt = SpotchatReceipt(envelopeID: message.id, digest: message.envelope.digest, sender: ownCard, destination: message.envelope.sender, read: read, timestamp: Int64(now().timeIntervalSince1970 * 1000), expiresAt: message.envelope.expiresAt)
        guard let signature = transport.noiseSignData(try receipt.signingBytes()) else { throw SpotchatFailure.unavailableIdentity }
        receipt.signature = signature
        try acceptReceipt(receipt)
    }
    private func acceptReceipt(_ receipt: SpotchatReceipt) throws {
        try receipt.validate(at: now())
        if let i = state.messages.firstIndex(where: { $0.id == receipt.envelopeID && $0.outgoing }) {
            let message = state.messages[i]
            guard message.envelope.digest == receipt.digest, message.envelope.recipient.id == receipt.sender.id,
                  message.envelope.recipient.signingKey == receipt.sender.signingKey, receipt.destination.id == ownCard.id else { throw SpotchatFailure.invalidMessage }
        }
        let old = state.receipts.first(where: { $0.receipt.key == receipt.key })
        if let old, old.receipt.read || !receipt.read { return }
        // Only the message's recipient may issue a deletion proof. Carry ACKs
        // along the original carrier graph, not arbitrary unsolicited proofs.
        let original = state.messages.first(where: { $0.id == receipt.envelopeID })?.envelope
            ?? state.relay.first(where: { $0.envelope.id == receipt.envelopeID })?.envelope
        if let original {
            guard original.digest == receipt.digest,
                  original.recipient.id == receipt.sender.id,
                  original.recipient.signingKey == receipt.sender.signingKey,
                  original.sender.id == receipt.destination.id else { return }
        } else {
            // A verified delivery proof can authenticate a later read upgrade
            // after this courier has already removed the encrypted message.
            guard let previous = old?.receipt, previous.digest == receipt.digest,
                  previous.sender.signingKey == receipt.sender.signingKey,
                  previous.destination.id == receipt.destination.id else { return }
        }
        guard state.receipts.count < 2000 || old != nil else { return }
        try store.transaction { state in
            state.receipts.removeAll { $0.receipt.key == receipt.key }
            state.receipts.append(SpotchatStoredReceipt(receipt: receipt))
            state.relay.removeAll { $0.envelope.id == receipt.envelopeID && $0.envelope.digest == receipt.digest && $0.envelope.recipient.id == receipt.sender.id && $0.envelope.recipient.signingKey == receipt.sender.signingKey }
            if let i = state.messages.firstIndex(where: { $0.id == receipt.envelopeID && $0.outgoing }) {
                if state.messages[i].status != .read { state.messages[i].status = receipt.read ? .read : .delivered }
                state.messages[i].deliveredAt = Date(timeIntervalSince1970: Double(receipt.timestamp) / 1000)
                if receipt.read { state.messages[i].readAt = state.messages[i].deliveredAt }
            }
        }; changed()
    }
    private func markRead() {
        guard foreground, let activeContact else { return }
        for message in state.messages where !message.outgoing && message.envelope.sender.id == activeContact && message.unread {
            do {
                try store.transaction { state in if let i = state.messages.firstIndex(where: { $0.id == message.id }) { state.messages[i].unread = false } }
                try makeReceipt(for: message, read: true); changed()
            } catch { fail(error); return }
        }
    }
    private func routeInvitationControls() {
        guard foreground, !retired else { return }
        for stored in (state.invitationOutbox ?? []).prefix(4) {
            let control = stored.control
            let direct = session(for: control.recipient)
            let canSendDirect = direct != nil
                && (control.action == .request || stored.attempts < 6)
            let canSendInternet = !stored.nostrAccepted && internet?.connected == true
            guard canSendDirect || canSendInternet else { continue }

            let exponent = min(stored.attempts, 5)
            let retryDelay = min(300.0, 10.0 * pow(2.0, Double(exponent)))
            guard now().timeIntervalSince(stored.lastAttempt) >= retryDelay else { continue }

            do {
                try store.transaction { state in
                    guard let index = state.invitationOutbox?.firstIndex(where: { $0.id == stored.id }) else { return }
                    state.invitationOutbox?[index].lastAttempt = now()
                    state.invitationOutbox?[index].attempts += 1
                }
                let packet = SpotchatPacket(invitation: control)
                if let direct, canSendDirect { sendPacket(packet, to: direct) }
                if canSendInternet {
                    internet?.send(packet, to: control.recipient) { [weak self] accepted in
                        guard let self, accepted, !self.retired else { return }
                        do {
                            try self.store.transaction { state in
                                guard let index = state.invitationOutbox?.firstIndex(where: { $0.id == stored.id }) else { return }
                                state.invitationOutbox?[index].nostrAccepted = true
                            }
                            self.changed()
                        } catch { self.fail(error) }
                    }
                }
                changed()
            } catch { fail(error); return }
        }
    }
    private func routeOutbox() {
        guard foreground, !retired else { return }
        var sent = 0
        for message in state.messages.filter({ $0.outgoing && [.queued, .forwarding].contains($0.status) }) {
            if sent >= 4 { break }
            let direct = session(for: message.envelope.recipient)
            let couriers = nearby.filter { $0.value.id != message.envelope.recipient.id && !message.forwardedTo.contains($0.value.id) }.sorted { $0.key.id < $1.key.id }
            guard direct != nil || internet?.connected == true || (!couriers.isEmpty && message.forwardedTo.count < 3), now().timeIntervalSince(message.lastAttempt) >= min(60, 10 * Double(max(1, message.attempts))) else { continue }
            do {
                sent += 1
                let courier = direct == nil && message.forwardedTo.count < 3 ? couriers.first : nil
                try store.transaction { state in
                    guard let i = state.messages.firstIndex(where: { $0.id == message.id }) else { return }
                    state.messages[i].attempts += 1; state.messages[i].lastAttempt = now()
                    if let courier { state.messages[i].forwardedTo.insert(courier.value.id) }
                    if direct != nil || courier != nil { state.messages[i].status = .forwarding; state.messages[i].deliveryTransport = direct != nil ? "ble" : "mesh" }
                }
                let packet = SpotchatPacket(envelope: message.envelope, hopCount: 1)
                if let direct { sendPacket(packet, to: direct) }
                else {
                    if let courier { sendPacket(packet, to: courier.key) }
                    if internet?.connected == true {
                        internet?.send(packet, to: message.envelope.recipient) { [weak self] accepted in
                            guard let self, accepted, !self.retired else { return }
                            do { try self.store.transaction { state in
                                if let i = state.messages.firstIndex(where: { $0.id == message.id }), [.queued, .forwarding].contains(state.messages[i].status) { state.messages[i].nostrAccepted = true; state.messages[i].status = .forwarding; state.messages[i].deliveryTransport = "nostr" }
                            }; self.changed() } catch { self.fail(error) }
                        }
                    }
                }; changed()
            } catch { fail(error); return }
        }
    }
    private func routeRelay() {
        guard foreground, !retired else { return }
        var sent = 0
        for copy in state.relay {
            if sent >= 8 { break }
            let direct = session(for: copy.envelope.recipient)
            let next = nearby.filter { !copy.forwardedTo.contains($0.value.id) && $0.value.id != copy.envelope.sender.id && $0.value.id != copy.envelope.recipient.id }.sorted { $0.key.id < $1.key.id }.first
            if let direct, copy.hopCount < copy.envelope.hopLimit, now().timeIntervalSince(copy.lastDirectAttempt) >= 30 {
                sent += 1
                do { try store.transaction { state in if let i = state.relay.firstIndex(where: { $0.envelope.id == copy.envelope.id }) { state.relay[i].lastDirectAttempt = now() } }
                    sendPacket(SpotchatPacket(envelope: copy.envelope, hopCount: copy.hopCount + 1), to: direct)
                } catch { fail(error) }
            } else if direct == nil, copy.hopCount < copy.envelope.hopLimit, copy.forwardedTo.count < 3, let next {
                sent += 1
                do { try store.transaction { state in if let i = state.relay.firstIndex(where: { $0.envelope.id == copy.envelope.id }) { state.relay[i].forwardedTo.insert(next.value.id) } }
                    sendPacket(SpotchatPacket(envelope: copy.envelope, hopCount: copy.hopCount + 1), to: next.key)
                } catch { fail(error) }
            }
        }
    }
    private func routeReceipts() {
        guard foreground, !retired else { return }
        var sent = 0
        for stored in state.receipts where now().timeIntervalSince(stored.lastAttempt) >= 30 {
            if sent >= 8 { break }
            let receipt = stored.receipt
            let direct = session(for: receipt.destination)
            let next = nearby.filter { !stored.sentTo.contains($0.value.id) && $0.key != direct }.prefix(8)
            let useInternet = receipt.sender.id == ownCard.id && !stored.nostrAccepted && internet?.connected == true
            guard direct != nil || !next.isEmpty || useInternet else { continue }
            sent += 1
            do {
                try store.transaction { state in if let i = state.receipts.firstIndex(where: { $0.receipt.key == receipt.key }) {
                    state.receipts[i].lastAttempt = now()
                    for pair in next { state.receipts[i].sentTo.insert(pair.value.id) }
                } }
                let packet = SpotchatPacket(receipt: receipt)
                if let direct { sendPacket(packet, to: direct) }
                for pair in next { sendPacket(packet, to: pair.key) }
                if useInternet { internet?.send(packet, to: receipt.destination) { [weak self] accepted in
                    guard let self, accepted, !self.retired else { return }
                    do { try self.store.transaction { state in if let i = state.receipts.firstIndex(where: { $0.receipt.key == receipt.key }) { state.receipts[i].nostrAccepted = true } } } catch { self.fail(error) }
                } }
            } catch { fail(error) }
        }
    }
    private func sendPacket(_ packet: SpotchatPacket, to peer: PeerID) {
        guard !retired, let bytes = try? SpotchatCoding.encode(packet), bytes.count <= 24_000 else { return }
        wire.sendSpotchatPacket(bytes, to: peer)
    }
    func isBlocked(_ card: SpotchatContactCard) -> Bool { state.blocked?[card.id] != nil }
    func deleteConversation(with card: SpotchatContactCard, removeContact: Bool = false) throws {
        guard !retired else { throw SpotchatFailure.unavailableIdentity }
        let conversationID = SpotchatConversation.identifier(ownCard.id, card.id)
        try store.transaction { state in
            // Ignore old relay/Nostr replays after local deletion. New messages
            // from a retained contact may create a new conversation.
            if state.deletedMessageIDs == nil { state.deletedMessageIDs = [:] }
            for message in state.messages where message.envelope.conversationID == conversationID {
                let expiry = Date(timeIntervalSince1970: Double(message.envelope.expiresAt) / 1000)
                if expiry > now() { state.deletedMessageIDs?[message.id] = expiry }
            }
            state.messages.removeAll { $0.envelope.conversationID == conversationID }
            state.legacyHistory?.messages.removeAll { $0.contactID == card.id }
            state.legacyHistory?.contacts.removeAll { $0.id == card.id }
            state.conversations.removeAll { $0.id == conversationID }
            state.receipts.removeAll { $0.receipt.sender.id == card.id || $0.receipt.destination.id == card.id }
            if removeContact {
                state.contacts.removeAll { $0.id == card.id }
                state.requests.removeAll { $0.id == card.id }
                state.invitationStates?.removeValue(forKey: card.id)
                state.invitationOutbox?.removeAll { $0.control.recipient.id == card.id }
            }
        }
        if activeContact == card.id { activeContact = nil }
        changed()
    }
    func clearDirectoryEntry(_ card: SpotchatContactCard) throws {
        guard !retired else { throw SpotchatFailure.unavailableIdentity }
        guard !isSaved(card) else { return }
        let conversationID = SpotchatConversation.identifier(ownCard.id, card.id)
        try store.transaction { state in
            if state.deletedMessageIDs == nil { state.deletedMessageIDs = [:] }
            for message in state.messages where message.envelope.conversationID == conversationID {
                let expiry = Date(
                    timeIntervalSince1970: Double(message.envelope.expiresAt) / 1000
                )
                if expiry > now() { state.deletedMessageIDs?[message.id] = expiry }
            }
            state.messages.removeAll { $0.envelope.conversationID == conversationID }
            state.legacyHistory?.messages.removeAll { $0.contactID == card.id }
            state.legacyHistory?.contacts.removeAll { $0.id == card.id }
            state.conversations.removeAll { $0.id == conversationID }
            state.receipts.removeAll {
                $0.receipt.sender.id == card.id
                    || $0.receipt.destination.id == card.id
            }
            state.contacts.removeAll { $0.id == card.id }
            state.requests.removeAll { $0.id == card.id }
            state.encounters?.removeAll { $0.id == card.id }
            state.unviewedEncounterIDs?.remove(card.id)
            state.invitationStates?.removeValue(forKey: card.id)
            state.invitationOutbox?.removeAll { $0.control.recipient.id == card.id }
        }
        if activeContact == card.id { activeContact = nil }
        nearby = nearby.filter { $0.value.id != card.id }
        changed()
    }
    func setBlocked(_ card: SpotchatContactCard, blocked: Bool) throws {
        guard !retired else { throw SpotchatFailure.unavailableIdentity }
        try card.validate()
        try store.transaction { state in
            if state.blocked == nil { state.blocked = [:] }
            if blocked {
                guard state.blocked!.count < 2000 || state.blocked?[card.id] != nil else { throw SpotchatFailure.quota }
                state.blocked?[card.id] = card
                state.requests.removeAll { $0.id == card.id }
                state.invitationOutbox?.removeAll { $0.control.recipient.id == card.id }
                state.relay.removeAll { $0.envelope.sender.id == card.id || $0.envelope.recipient.id == card.id || $0.depositor == card.id }
                state.receipts.removeAll { $0.receipt.sender.id == card.id || $0.receipt.destination.id == card.id }
                for i in state.messages.indices where state.messages[i].outgoing && state.messages[i].envelope.recipient.id == card.id && [.queued, .forwarding].contains(state.messages[i].status) {
                    state.messages[i].status = .cancelled
                }
            } else { state.blocked?.removeValue(forKey: card.id) }
        }
        if blocked { nearby = nearby.filter { $0.value.id != card.id } }
        changed()
    }
    // Prevent all delayed callbacks from saving or sending after profile deletion.
    func retire() {
        retired = true; foreground = false; activeContact = nil
        internet?.received = nil; internet?.stop()
        nearby.removeAll(); helloTimes.removeAll(); ingressRate.removeAll()
    }
    private func changed() { revision &+= 1 }
    private func fail(_ error: Error) { onError?(error.localizedDescription) }
}
