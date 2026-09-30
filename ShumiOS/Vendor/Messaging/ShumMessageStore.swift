import BitFoundation
import Combine
import Foundation

/// Application-level outbox/relay coordinator. It never controls CoreBluetooth.
/// All message crypto and link writes delegate to the existing bitchat stack.
@MainActor
final class ShumMessageStore: ObservableObject {
    static let encounterRetention: TimeInterval = 24 * 60 * 60
    static let invitationLifetimeMilliseconds: Int64 = 30 * 86_400_000
    static let typingLifetimeMilliseconds: Int64 = 8_000
    // "In chat" is renewed well before it expires, so a lost relay event or a
    // closed app leaves a stale mark for at most the lifetime.
    static let presenceLifetimeMilliseconds: Int64 = 40_000
    static let presenceBroadcastInterval: TimeInterval = 25
    static let presenceFlushTimeout: TimeInterval = 4
    // A nearby contact gets the message over Bluetooth and shows its own
    // notification; the push waits this long for that delivery first.
    static let directDeliveryPushDelay: TimeInterval = 8
    @Published private(set) var revision = 0
    let store: ShumConversationStore
    let contacts: ShumContactsService
    private let identity: ShumIdentityService
    private let crypto: ShumCryptoService
    private let transport: Transport
    private let wire: ShumSecureTransport
    private let internet: (any ShumInternetTransport)?
    private let now: () -> Date
    var ownCard: ShumContactCard
    var onError: ((String) -> Void)?
    /// Incoming messages the sender withdrew, so their notifications can go too.
    var onMessagesRetracted: (([String]) -> Void)?
    private(set) var nearby: [PeerID: ShumContactCard] = [:]
    private var helloTimes: [PeerID: Date] = [:]
    private var ingressRate: [String: (Date, Int)] = [:]
    private var activeContact: String?
    private var foreground = true
    private var tickNumber = 0
    private var localSessionID: PeerID?
    private var retired = false
    private var typingDeadlines: [String: Date] = [:]
    private var latestTypingEvents: [String: (timestamp: Int64, id: String)] = [:]
    private var lastTypingSent: [String: (active: Bool, sentAt: Date)] = [:]
    private var presenceDeadlines: [String: Date] = [:]
    private var latestPresenceEvents: [String: (timestamp: Int64, id: String)] = [:]
    private var lastPresenceByContact: [String: Date] = [:]
    /// Receivers keep the newest presence event, so each signal is strictly
    /// later than the previous one even within the same millisecond.
    private var lastPresenceMilliseconds: Int64 = 0
    /// Set while the "left" signal sent on backgrounding awaits the relay.
    private var presenceFlushID: UUID?
    /// Lets the app release the background time it requested for the flush.
    var onPresenceFlushFinished: (() -> Void)?
    var requestPush: (_ recipientID: String, _ eventID: String, _ kind: ShumPushKind) -> Void = {
        ShumPushService.shared.notify(recipientID: $0, eventID: $1, kind: $2)
    }
    /// Pushes held while a Bluetooth delivery to a nearby contact may still finish.
    private var heldPushes: [String: (recipientID: String, due: Date)] = [:]
    private var backgroundFetchTask: Task<Void, Never>?
    private var backgroundFetchCompletions:
        [(eventID: String, completion: (Bool) -> Void)] = []

    init(identity: ShumIdentityService, store: ShumConversationStore, transport: Transport,
         wire: ShumSecureTransport, card: ShumContactCard,
         internet: (any ShumInternetTransport)?, now: @escaping () -> Date = Date.init) throws {
        self.identity = identity; self.store = store; self.transport = transport; self.wire = wire
        self.crypto = ShumCryptoService(wire: wire); self.ownCard = card
        self.contacts = ShumContactsService(store: store); self.internet = internet; self.now = now
        if let saved = store.state.ownProfileCard {
            try saved.validate()
            guard saved.noiseKey == card.noiseKey, saved.signingKey == card.signingKey,
                  saved.nostrKey == card.nostrKey else { throw ShumFailure.unavailableIdentity }
            self.ownCard = saved
        }
        if state.ownProfileCard == nil, card.profileRevision != nil {
            try card.validate()
            try commitOwnProfile(card)
        } else {
            try updateProfile(name: card.name, bio: card.bio, avatarSeed: card.avatarSeed)
        }
        try queueProfileReconciliation()
        internet?.received = { [weak self] packet, sender in self?.receive(packet, from: nil, nostrSender: sender) }
        ShumPushService.shared.configure(card: ownCard) { [weak transport] data in
            transport?.noiseSignData(data)
        }
    }
    var internetConnected: Bool { internet?.connected == true }
    var state: ShumDatabase { store.state }

    func configureContactLookup(profile: @escaping () -> ShumProfile?) {
        internet?.configureContactLookup(
            card: { [weak self] in self?.ownCard },
            profile: profile
        )
    }

    func resolve(_ locator: ShumContactLocator, completion: @escaping (Result<ShumResolvedContact, Error>) -> Void) {
        guard let internet else {
            completion(.failure(ShumFailure.contactUnavailable))
            return
        }
        internet.resolve(locator, completion: completion)
    }

    var encounterHistory: [ShumEncounter] {
        (state.encounters ?? [])
            .filter {
                !isBlocked($0.card)
                    && $0.lastSeen >= now().addingTimeInterval(-Self.encounterRetention)
            }
            .sorted { $0.lastSeen > $1.lastSeen }
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
    func fetchRemoteEvents(
        eventID: String,
        completion: @escaping (Bool) -> Void
    ) {
        guard !retired, internet != nil else {
            completion(false)
            return
        }
        if containsRemoteEvent(eventID) {
            completion(false)
            return
        }
        backgroundFetchCompletions.append((eventID, completion))
        internet?.start()
        guard backgroundFetchTask == nil else { return }
        backgroundFetchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled, let self else { return }
            let completions = self.backgroundFetchCompletions
            self.backgroundFetchCompletions.removeAll()
            self.backgroundFetchTask = nil
            if !self.foreground, self.presenceFlushID == nil { self.internet?.stop() }
            for pending in completions {
                pending.completion(self.containsRemoteEvent(pending.eventID))
            }
        }
    }
    private func containsRemoteEvent(_ eventID: String) -> Bool {
        state.messages.contains { !$0.outgoing && $0.id == eventID }
            || state.invitationStates?.values.contains {
                $0.eventID == eventID
            } == true
    }
    private func finishReceivedRemoteEvents() {
        guard !backgroundFetchCompletions.isEmpty else { return }
        var remaining: [(eventID: String, completion: (Bool) -> Void)] = []
        for pending in backgroundFetchCompletions {
            if containsRemoteEvent(pending.eventID) {
                pending.completion(true)
            } else {
                remaining.append(pending)
            }
        }
        backgroundFetchCompletions = remaining
        // Keep the relay connection until the bounded wake window ends. The
        // delivery receipt is sent just after the message is saved, and
        // closing the socket here can cancel its relay acknowledgement.
    }
    func setActive(_ active: Bool) {
        guard !retired else { return }
        if active {
            foreground = true
            finishPresenceFlush()
            do { try queueProfileReconciliation() } catch { fail(error) }
            internet?.start()
            // The chat still open on return is announced on the next tick,
            // not after the regular renewal interval.
            if let activeContact { lastPresenceByContact.removeValue(forKey: activeContact) }
            markRead()
            return
        }
        foreground = false
        // A suspended app cannot wait for the Bluetooth receipt any longer.
        sendHeldPushes(force: true)
        // Keep the relay connection until it accepts "left"; cutting it in
        // the same moment dropped the signal and left a stale "in chat".
        let flushID = UUID()
        let sent = sendPresence(online: false, to: activeContact) { [weak self] in
            self?.finishPresenceFlush(flushID)
        }
        if sent, presenceFlushID == nil {
            presenceFlushID = flushID
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.presenceFlushTimeout) { [weak self] in
                self?.finishPresenceFlush(flushID)
            }
        } else if backgroundFetchTask == nil {
            internet?.stop()
            onPresenceFlushFinished?()
        }
    }

    /// Ends the background flush (all flushes when `id` is nil) and closes the
    /// relay connection unless the app returned or a background fetch runs.
    private func finishPresenceFlush(_ id: UUID? = nil) {
        guard let current = presenceFlushID, id == nil || id == current else { return }
        presenceFlushID = nil
        if !foreground, backgroundFetchTask == nil { internet?.stop() }
        onPresenceFlushFinished?()
    }
    func updateProfile(name: String, bio: String, avatarSeed: UInt64? = nil) throws {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        if state.ownProfileCard != nil, ownCard.name == name, ownCard.bio == bio,
           ownCard.avatarSeed == avatarSeed { return }
        let revision = state.ownProfileCard == nil ? UInt64(1) : try nextProfileRevision(ownCard.profileRevision ?? 0)
        let next = try identity.card(name: name, bio: bio, avatarSeed: avatarSeed, revision: revision)
        try commitOwnProfile(next)
    }
    private func nextProfileRevision(_ revision: UInt64) throws -> UInt64 {
        guard revision < UInt64.max else { throw ShumFailure.invalidContact }
        return revision + 1
    }
    private func commitOwnProfile(_ card: ShumContactCard) throws {
        try store.transaction { state in
            state.ownProfileCard = card
            state.profileOutbox = state.contacts.filter { state.blocked?[$0.id] == nil }.map {
                ShumProfileDelivery(recipientID: $0.id, profileID: card.profileID)
            }
        }
        ownCard = card
        helloTimes.removeAll()
        ShumPushService.shared.configure(card: ownCard) { [weak transport] data in
            transport?.noiseSignData(data)
        }
        changed()
    }

    /// All transports share the same signature/version merge and persistent head.
    @discardableResult
    private func mergeProfile(_ incoming: ShumContactCard) throws -> ShumContactCard {
        var head = incoming
        for current in nearby.values where current.id == incoming.id {
            head = try head.preferred(over: current)
        }
        let card = try contacts.merge(head)
        for peer in Array(nearby.keys) where nearby[peer]?.id == card.id {
            nearby[peer] = card
        }
        changed()
        return card
    }

    private func profilePacket(to card: ShumContactCard, reply: Bool) throws -> ShumPacket {
        var sync = ShumProfileSync(sender: ownCard, recipientID: card.id,
            knownRecipient: try contacts.freshest(card), requestsReply: reply)
        guard let signature = transport.noiseSignData(try sync.signingBytes()) else {
            throw ShumFailure.unavailableIdentity
        }
        sync.signature = signature
        return ShumPacket(profileSync: sync)
    }

    private func receiveProfile(_ sync: ShumProfileSync, from peer: PeerID?, nostrSender: String?) throws {
        try sync.validate()
        guard sync.recipientID == ownCard.id, !isBlocked(sync.sender),
              state.contacts.contains(where: { $0.id == sync.sender.id }) else { return }
        if let peer {
            guard transport.noiseSessionPublicKeyData(for: peer) == sync.sender.noiseKey else { return }
        } else if nostrSender != sync.sender.nostrKey { return }
        let sender = try mergeProfile(sync.sender)
        if let known = sync.knownRecipient {
            let preferred = try known.preferred(over: ownCard)
            if preferred.profileID != ownCard.profileID {
                // The peer retained a newer head than our restored backup.
                // Rebase the local choice; never reset the counter on restore.
                let rebased = try identity.card(name: ownCard.name, bio: ownCard.bio,
                    avatarSeed: ownCard.avatarSeed, revision: nextProfileRevision(known.profileRevision ?? 0))
                try commitOwnProfile(rebased)
            } else if known.profileID == ownCard.profileID {
                try store.transaction { state in
                    state.profileOutbox?.removeAll {
                        $0.recipientID == sender.id && $0.profileID == known.profileID
                    }
                }
            }
        }
        if sync.requestsReply {
            let packet = try profilePacket(to: sender, reply: false)
            if let peer { sendPacket(packet, to: peer) }
            else { internet?.send(packet, to: sender) { _ in } }
        }
    }

    private func queueProfileReconciliation() throws {
        let missing = state.contacts.filter { contact in
            !isBlocked(contact.card) && !(state.profileOutbox ?? []).contains { $0.recipientID == contact.id }
        }
        guard !missing.isEmpty else { return }
        try store.transaction { state in
            if state.profileOutbox == nil { state.profileOutbox = [] }
            state.profileOutbox?.append(contentsOf: missing.map {
                ShumProfileDelivery(recipientID: $0.id, profileID: ownCard.profileID)
            })
        }
    }

    private func routeProfiles() {
        var sent = 0
        for pending in state.profileOutbox ?? [] {
            guard sent < 4 else { break }
            guard let card = state.contacts.first(where: { $0.id == pending.recipientID })?.card,
                  !isBlocked(card) else { continue }
            let peer = session(for: card)
            guard peer != nil || internet?.connected == true else { continue }
            let delay = min(3600.0, 5.0 * pow(2, Double(min(pending.attempts, 10))))
            guard now().timeIntervalSince(pending.lastAttempt ?? .distantPast) >= delay else { continue }
            do {
                let packet = try profilePacket(to: card, reply: true)
                try store.transaction { state in
                    if let index = state.profileOutbox?.firstIndex(where: { $0.recipientID == card.id }) {
                        state.profileOutbox?[index].lastAttempt = now()
                        state.profileOutbox?[index].attempts = min(pending.attempts + 1, 20)
                    }
                }
                if let peer { sendPacket(packet, to: peer) }
                if internet?.connected == true { internet?.send(packet, to: card) { _ in } }
                sent += 1
            } catch { fail(error); return }
        }
    }

    func card(for peer: PeerID) -> ShumContactCard? {
        state.contacts.first(where: { $0.card.peerID == peer })?.card
            ?? nearby[peer]
            ?? state.encounters?.first(where: { $0.card.peerID == peer })?.card
            ?? state.requests.first(where: { $0.peerID == peer })
            ?? state.blocked?.values.first(where: { $0.peerID == peer })
    }
    func session(for card: ShumContactCard) -> PeerID? {
        nearby.first(where: { $0.value.id == card.id && transport.isPeerConnected($0.key) && transport.noiseSessionPublicKeyData(for: $0.key) == card.noiseKey })?.key
    }
    func avatar(for card: ShumContactCard) -> Data? {
        state.invitationStates?[card.id]?.avatar
            ?? state.contacts.first(where: { $0.id == card.id })?.avatar
            ?? state.encounters?.first(where: { $0.id == card.id })?.avatar
    }
    func add(_ card: ShumContactCard, source: String, avatar: Data? = nil) throws {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        guard !isBlocked(card) else { throw ShumFailure.blocked }
        let isNew = !state.contacts.contains { $0.id == card.id }
        try contacts.add(card, source: source, avatar: avatar, now: now())
        try contacts.conversation(with: card, now: now())
        try store.transaction { state in
            if isNew {
                if state.profileOutbox == nil { state.profileOutbox = [] }
                state.profileOutbox?.append(ShumProfileDelivery(recipientID: card.id,
                    profileID: ownCard.profileID))
            }
            if state.invitationStates == nil { state.invitationStates = [:] }
            if state.invitationStates?[card.id] == nil {
                state.invitationStates?[card.id] = ShumInvitationState(
                    phase: source == "preview" ? .accepted : .ready,
                    updatedAt: Int64(now().timeIntervalSince1970 * 1000),
                    eventID: UUID().uuidString
                )
            }
        }
        changed()
    }
    func isAddressBookContact(_ card: ShumContactCard) -> Bool {
        state.contacts.first(where: { $0.id == card.id })?.isAddressBookEntry == true
    }
    func isAddressBookContact(_ peer: PeerID) -> Bool {
        state.contacts.first(where: { $0.card.peerID == peer })?.isAddressBookEntry == true
    }
    func removeFromContacts(_ card: ShumContactCard) throws {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        try store.transaction { state in
            guard let index = state.contacts.firstIndex(where: { $0.id == card.id }) else { return }
            state.contacts[index].metadata["addressBook"] = "false"
        }
        changed()
    }
    func dismissRequest(_ card: ShumContactCard) {
        _ = declineInvitation(card)
    }
    func invitationPhase(for card: ShumContactCard) -> ShumInvitationPhase {
        if let phase = state.invitationStates?[card.id]?.phase { return phase }
        if state.requests.contains(where: { $0.id == card.id }) { return .incomingPending }
        return .ready
    }
    func canMessage(_ card: ShumContactCard) -> Bool {
        invitationPhase(for: card) == .accepted
    }
    func isTyping(_ card: ShumContactCard) -> Bool {
        typingDeadlines[card.id].map { $0 > now() } == true
    }
    /// Contacts currently typing to this device.
    var typingCards: [ShumContactCard] {
        state.contacts.map(\.card).filter { isTyping($0) }
    }
    /// The contact has this conversation open, per its signed presence.
    func isInChat(_ card: ShumContactCard) -> Bool {
        presenceDeadlines[card.id].map { $0 > now() } == true
    }

    func setTyping(_ active: Bool, for card: ShumContactCard) {
        guard !retired, foreground, !isBlocked(card), canMessage(card),
              state.contacts.contains(where: { $0.id == card.id }) else { return }
        let timestamp = now()
        if let last = lastTypingSent[card.id] {
            if last.active == active {
                if !active || timestamp.timeIntervalSince(last.sentAt) < 4 { return }
            }
        } else if !active {
            return
        }
        do {
            let milliseconds = Int64(timestamp.timeIntervalSince1970 * 1000)
            var control = ShumTypingControl(
                id: UUID().uuidString,
                sender: ownCard,
                recipient: card,
                isTyping: active,
                timestamp: milliseconds,
                expiresAt: milliseconds + Self.typingLifetimeMilliseconds
            )
            guard let signature = transport.noiseSignData(try control.signingBytes()) else { return }
            control.signature = signature
            let packet = ShumPacket(typing: control)
            if let peer = session(for: card) { sendPacket(packet, to: peer) }
            internet?.send(packet, to: card) { _ in }
            lastTypingSent[card.id] = (active, timestamp)
        } catch { /* Typing is ephemeral and must never interrupt the chat. */ }
    }
    @discardableResult
    func sendInvitation(_ card: ShumContactCard) -> Bool {
        guard !retired, !isBlocked(card), invitationPhase(for: card) == .ready else { return false }
        do {
            try contacts.add(
                card,
                source: "chat-invitation",
                now: now(),
                includeInAddressBook: false
            )
            try contacts.conversation(with: card, now: now())
            try transitionInvitation(with: card, action: .request, phase: .outgoingPending)
            return true
        } catch { fail(error); return false }
    }
    @discardableResult
    func acceptInvitation(_ card: ShumContactCard) -> Bool {
        let phase = invitationPhase(for: card)
        guard !retired, !isBlocked(card), phase == .incomingPending || phase == .declinedLocally else { return false }
        do {
            try contacts.add(
                card,
                source: "accepted-invitation",
                avatar: avatar(for: card),
                now: now(),
                includeInAddressBook: false
            )
            try contacts.conversation(with: card, now: now())
            try transitionInvitation(with: card, action: .accept, phase: .accepted, removesRequest: true)
            return true
        } catch { fail(error); return false }
    }
    @discardableResult
    func declineInvitation(_ card: ShumContactCard) -> Bool {
        guard !retired, !isBlocked(card), invitationPhase(for: card) == .incomingPending else { return false }
        do {
            try transitionInvitation(with: card, action: .decline, phase: .declinedLocally)
            return true
        } catch { fail(error); return false }
    }

    private func transitionInvitation(
        with card: ShumContactCard,
        action: ShumInvitationAction,
        phase: ShumInvitationPhase,
        removesRequest: Bool = false,
        afterTimestamp: Int64? = nil
    ) throws {
        let previousTimestamp = state.invitationStates?[card.id]?.updatedAt ?? 0
        let timestamp = max(
            Int64(now().timeIntervalSince1970 * 1000),
            previousTimestamp + 1,
            (afterTimestamp ?? Int64.min) + 1
        )
        var control = ShumInvitationControl(
            id: UUID().uuidString,
            sender: ownCard,
            recipient: card,
            action: action,
            timestamp: timestamp,
            expiresAt: timestamp + Self.invitationLifetimeMilliseconds
        )
        guard let signature = transport.noiseSignData(try control.signingBytes()) else {
            throw ShumFailure.unavailableIdentity
        }
        control.signature = signature
        try store.transaction { state in
            if state.invitationStates == nil { state.invitationStates = [:] }
            if state.invitationOutbox == nil { state.invitationOutbox = [] }
            let previousAvatar = state.invitationStates?[card.id]?.avatar
            state.invitationStates?[card.id] = ShumInvitationState(
                phase: phase,
                updatedAt: timestamp,
                eventID: control.id,
                avatar: previousAvatar
            )
            state.invitationOutbox?.removeAll {
                $0.control.recipient.id == card.id
            }
            state.invitationOutbox?.append(
                ShumStoredInvitationControl(control: control, avatar: nil)
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
            internet?.send(ShumPacket(card: ownCard), to: card) { _ in }
        } else if action == .accept {
            if let peer = session(for: card) {
                sendPacket(ShumPacket(card: ownCard), to: peer)
            }
            internet?.send(ShumPacket(card: ownCard), to: card) { _ in }
        }
    }

    private func receiveInvitation(_ control: ShumInvitationControl, avatar _: ShumInvitationAvatar?) throws {
        try control.validate(at: now())
        guard control.recipient.noiseKey == ownCard.noiseKey,
              control.recipient.signingKey == ownCard.signingKey,
              control.recipient.nostrKey == ownCard.nostrKey,
              control.sender.id != ownCard.id else {
            throw ShumFailure.invalidMessage
        }

        try mergeProfile(control.sender)
        let currentPhase = invitationPhase(for: control.sender)
        if state.invitationStates?[control.sender.id]?.eventID == control.id {
            return
        }
        let avatar: Data? = nil
        let legacyIncomingRequest = currentPhase == .incomingPending
            && state.invitationStates?[control.sender.id]?.eventID.hasPrefix("legacy-") == true
        let hasOutgoingRequest = (state.invitationOutbox ?? []).contains {
            $0.control.recipient.id == control.sender.id
                && $0.control.action == .request
        }
        // Repair a reversal already saved by an older build, but only when
        // the local contact record proves that we initiated the invitation.
        let reversedLegacyRequest = legacyIncomingRequest
            && state.contacts.contains {
                $0.id == control.sender.id && $0.metadata["source"] == "chat-invitation"
            }
        switch control.action {
        case .request:
            // A previous build could erase only this device's accepted state
            // while clearing its local history. The other participant still
            // correctly considers the conversation accepted. Reaffirm that
            // acceptance once so the mismatched device repairs itself instead
            // of leaving a new request stuck forever.
            if currentPhase == .accepted {
                let currentTimestamp = state.invitationStates?[control.sender.id]?.updatedAt ?? 0
                guard control.timestamp > currentTimestamp else { return }
                try transitionInvitation(
                    with: control.sender,
                    action: .accept,
                    phase: .accepted,
                    removesRequest: true,
                    afterTimestamp: control.timestamp
                )
                return
            }
            if currentPhase == .outgoingPending,
               ownCard.id < control.sender.id {
                // Both people can tap Invite before either request arrives.
                // The lower stable identity remains the requester on both
                // devices, so the two states cannot flip to incomingPending.
                return
            }
            guard currentPhase == .ready
                    || currentPhase == .outgoingPending
                    || currentPhase == .declinedByPeer
                    || legacyIncomingRequest else { return }
            try store.transaction { state in
                if let index = state.requests.firstIndex(where: { $0.id == control.sender.id }) {
                    state.requests[index] = control.sender
                } else {
                    guard state.requests.count < 20 else { throw ShumFailure.quota }
                    state.requests.append(control.sender)
                }
                if state.invitationStates == nil { state.invitationStates = [:] }
                state.invitationStates?[control.sender.id] = ShumInvitationState(
                    phase: .incomingPending,
                    updatedAt: control.timestamp,
                    eventID: control.id,
                    avatar: avatar
                )
                state.invitationOutbox?.removeAll {
                    $0.control.recipient.id == control.sender.id
                        && $0.control.action == .request
                }
            }
        case .accept:
            guard currentPhase == .outgoingPending
                    || currentPhase == .declinedByPeer
                    || currentPhase == .accepted
                    || (currentPhase == .incomingPending && hasOutgoingRequest)
                    || reversedLegacyRequest else { return }
            try contacts.add(
                control.sender,
                source: "invitation-accepted",
                avatar: avatar,
                now: now(),
                includeInAddressBook: false
            )
            try contacts.conversation(with: control.sender, now: now())
            try store.transaction { state in
                if state.invitationStates == nil { state.invitationStates = [:] }
                state.invitationStates?[control.sender.id] = ShumInvitationState(
                    phase: .accepted,
                    updatedAt: control.timestamp,
                    eventID: control.id,
                    avatar: avatar
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
                state.invitationStates?[control.sender.id] = ShumInvitationState(
                    phase: .declinedByPeer,
                    updatedAt: control.timestamp,
                    eventID: control.id,
                    avatar: avatar
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
    func open(_ card: ShumContactCard?) {
        guard !retired else { return }
        if let previous = activeContact, previous != card?.id, foreground {
            // Switching or leaving ends "in chat" for the previous contact now.
            sendPresence(online: false, to: previous)
        }
        activeContact = card?.id
        if let card {
            do {
                let count = state.conversations.count
                try contacts.conversation(with: card, now: now())
                if state.conversations.count != count { changed() }
            } catch { fail(error) }
            if foreground { sendPresence(online: true, to: card.id) }
        }
        markRead()
    }
    /// A chat reports disappearing after the next one may have appeared, so
    /// only the chat that is still open is closed.
    func close(_ card: ShumContactCard) {
        guard !retired, activeContact == card.id else { return }
        open(nil)
    }
    func updateAvatar(_ avatar: Data?, for peer: PeerID) {
        guard !retired else { return }
        guard (avatar?.count ?? 0) <= 40_960, let card = nearby[peer] else { return }
        let contactNeedsUpdate = state.contacts.first(where: { $0.id == card.id })?.avatar != avatar
        let encounterNeedsUpdate = state.encounters?.first(where: { $0.id == card.id })?.avatar != avatar
        let invitationNeedsUpdate = state.invitationStates?[card.id].map { $0.avatar != avatar } ?? false
        guard contactNeedsUpdate || encounterNeedsUpdate || invitationNeedsUpdate else { return }
        do {
            try store.transaction { state in
                if let index = state.contacts.firstIndex(where: { $0.id == card.id }) {
                    state.contacts[index].avatar = avatar
                }
                if let index = state.encounters?.firstIndex(where: { $0.id == card.id }) {
                    state.encounters?[index].avatar = avatar
                }
                state.invitationStates?[card.id]?.avatar = avatar
            }
            changed()
        } catch { fail(error) }
    }

    func recordEncounter(_ incoming: ShumContactCard, avatar: Data? = nil) throws {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        guard incoming.id != ownCard.id, !isBlocked(incoming), (avatar?.count ?? 0) <= 40_960 else { return }
        let card = try mergeProfile(incoming)
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
                    throw ShumFailure.invalidContact
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
                    ShumEncounter(
                        card: card,
                        firstSeen: timestamp,
                        lastSeen: timestamp,
                        seenCount: 1,
                        avatar: avatar
                    )
                )
                state.unviewedEncounterIDs?.insert(card.id)
                if let count = state.encounters?.count, count > 1_000 {
                    state.encounters = state.encounters?
                        .sorted { $0.lastSeen > $1.lastSeen }
                        .prefix(1_000)
                        .map { $0 }
                }
            }
        }
        changed()
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

    func isPinned(_ card: ShumContactCard, in directory: String) -> Bool {
        state.pinnedDirectoryEntries?[directory]?.contains(card.id) == true
    }

    func pinnedCardIDs(in directory: String) -> [String] {
        state.pinnedDirectoryEntries?[directory] ?? []
    }

    @discardableResult
    func togglePinned(_ card: ShumContactCard, in directory: String) throws -> Bool {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        try card.validate()
        guard card.id != ownCard.id, !isBlocked(card), !directory.isEmpty else {
            throw ShumFailure.invalidContact
        }
        var pinned = false
        try store.transaction { state in
            if state.pinnedDirectoryEntries == nil { state.pinnedDirectoryEntries = [:] }
            var entries = state.pinnedDirectoryEntries?[directory] ?? []
            if let index = entries.firstIndex(of: card.id) {
                entries.remove(at: index)
                if entries.isEmpty {
                    state.pinnedDirectoryEntries?.removeValue(forKey: directory)
                } else {
                    state.pinnedDirectoryEntries?[directory] = entries
                }
            } else {
                entries.removeAll { $0 == card.id }
                entries.insert(card.id, at: 0)
                state.pinnedDirectoryEntries?[directory] = entries
                pinned = true
            }
        }
        changed()
        return pinned
    }

    func deleteEncounter(_ card: ShumContactCard) {
        guard !retired, state.encounters?.contains(where: { $0.id == card.id }) == true else { return }
        do {
            try store.transaction { state in
                state.encounters?.removeAll { $0.id == card.id }
                state.unviewedEncounterIDs?.remove(card.id)
                state.pinnedDirectoryEntries?["encounters"]?.removeAll { $0 == card.id }
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
                state.pinnedDirectoryEntries?.removeValue(forKey: "encounters")
            }
            changed()
        } catch { fail(error) }
    }
    @discardableResult
    func send(_ text: String, to card: ShumContactCard, reply: ShumReplyReference? = nil) -> Bool {
        guard !retired else { return false }
        guard !isBlocked(card) else { fail(ShumFailure.blocked); return false }
        guard canMessage(card) else { return false }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= 4096 else { onError?("Сообщение должно быть не длиннее 4096 байт.".localized); return false }
        do {
            if !state.contacts.contains(where: { $0.id == card.id }) {
                throw ShumFailure.invalidContact
            }
            guard state.messages.filter({ $0.outgoing && [.queued, .forwarding].contains($0.status) }).count < 200 else { throw ShumFailure.quota }
            let id = UUID().uuidString, timestamp = Int64(now().timeIntervalSince1970 * 1000)
            let conversation = ShumConversation.identifier(ownCard.id, card.id)
            let payload = ShumPlaintext(id: id, conversationID: conversation, senderID: ownCard.id, recipientID: card.id,
                                           timestamp: timestamp, expiresAt: timestamp + 86_400_000, text: text,
                                           reply: reply)
            var envelope = ShumEnvelope(id: id, conversationID: conversation, sender: ownCard, recipient: card,
                timestamp: timestamp, expiresAt: payload.expiresAt, ciphertext: try crypto.seal(ShumCoding.encode(payload), to: card.noiseKey))
            guard let signature = transport.noiseSignData(try envelope.signingBytes()) else { throw ShumFailure.unavailableIdentity }
            envelope.signature = signature
            try contacts.conversation(with: card, now: now())
            try store.transaction {
                $0.messages.append(ShumStoredMessage(envelope: envelope, text: text, outgoing: true,
                                                         status: .queued, reply: reply))
            }
            changed(); routeOutbox(); return true
        } catch { fail(error); return false }
    }
    /// Sends an expired message again at the end of the chat and removes the
    /// failed one, so repeated taps on "Retry" never leave duplicates.
    @discardableResult
    func resend(_ messageID: String, to card: ShumContactCard) -> Bool {
        guard !retired,
              let failed = state.messages.first(where: { $0.id == messageID && $0.outgoing }),
              failed.status == .expired,
              failed.envelope.recipient.id == card.id,
              send(failed.text, to: card, reply: failed.reply) else { return false }
        do {
            try store.transaction { $0.messages.removeAll { $0.id == messageID } }
            changed(); return true
        } catch { fail(error); return false }
    }
    func reaction(of personID: String, on messageID: String) -> ShumReaction? {
        state.reactions?[messageID]?[personID]?.reaction
    }
    /// Sets the user's single reaction on a message. Choosing the reaction that
    /// is already there takes it back. The contact gets it without a push.
    @discardableResult
    func toggleReaction(_ reaction: ShumReaction, on messageID: String) -> Bool {
        guard !retired, let message = state.messages.first(where: { $0.id == messageID }) else { return false }
        let peer = message.outgoing ? message.envelope.recipient : message.envelope.sender
        guard let contact = state.contacts.first(where: { $0.id == peer.id })?.card,
              !isBlocked(contact), canMessage(contact) else { return false }
        let current = state.reactions?[messageID]?[ownCard.id]
        let next: ShumReaction? = current?.reaction == reaction ? nil : reaction
        let timestamp = max(Int64(now().timeIntervalSince1970 * 1000), (current?.timestamp ?? 0) + 1)
        do {
            var control = ShumReactionControl(
                id: UUID().uuidString, sender: ownCard, recipient: contact, messageID: messageID,
                reaction: next, timestamp: timestamp,
                expiresAt: timestamp + ShumReactionControl.lifetimeMilliseconds
            )
            guard let signature = transport.noiseSignData(try control.signingBytes()) else {
                throw ShumFailure.unavailableIdentity
            }
            control.signature = signature
            try store.transaction { state in
                if state.reactions == nil { state.reactions = [:] }
                state.reactions?[messageID, default: [:]][ownCard.id] =
                    ShumReactionMark(reaction: next, timestamp: timestamp, eventID: control.id)
                // Only the latest choice is worth delivering.
                if state.reactionOutbox == nil { state.reactionOutbox = [] }
                state.reactionOutbox?.removeAll { $0.control.messageID == messageID }
                state.reactionOutbox?.append(ShumStoredReaction(control: control))
            }
            changed(); route(\.reactionOutbox); return true
        } catch { fail(error); return false }
    }
    /// Removes an undelivered message. If a copy already left the phone, the
    /// contact gets a signed withdrawal so the copy is dropped there as well.
    @discardableResult
    func cancelSending(_ messageID: String) -> Bool {
        guard !retired,
              let message = state.messages.first(where: { $0.id == messageID && $0.outgoing }),
              [.queued, .forwarding].contains(message.status) else { return false }
        let leftPhone = message.attempts > 0 || message.nostrAccepted
            || message.lastNostrAttempt != nil || !message.forwardedTo.isEmpty
        do {
            var retract: ShumStoredRetract?
            if leftPhone {
                var control = ShumRetractControl(
                    id: UUID().uuidString,
                    sender: ownCard,
                    recipient: message.envelope.recipient,
                    messageID: messageID,
                    timestamp: Int64(now().timeIntervalSince1970 * 1000),
                    expiresAt: message.envelope.expiresAt
                )
                guard let signature = transport.noiseSignData(try control.signingBytes()) else {
                    throw ShumFailure.unavailableIdentity
                }
                control.signature = signature
                retract = ShumStoredRetract(control: control)
            }
            try store.transaction { state in
                state.messages.removeAll { $0.id == messageID }
                state.reactions?.removeValue(forKey: messageID)
                state.reactionOutbox?.removeAll { $0.control.messageID == messageID }
                if let retract {
                    if state.retractOutbox == nil { state.retractOutbox = [] }
                    state.retractOutbox?.append(retract)
                }
            }
            heldPushes.removeValue(forKey: messageID)
            changed(); route(\.retractOutbox); return true
        } catch { fail(error); return false }
    }
    func tick(connected: Set<PeerID>, active: Bool) {
        guard !retired else { return }
        tickNumber += 1
        let expiredTyping = typingDeadlines.filter { $0.value <= now() }.map(\.key)
        let expiredPresence = presenceDeadlines.filter { $0.value <= now() }.map(\.key)
        if !expiredTyping.isEmpty || !expiredPresence.isEmpty {
            for id in expiredTyping { typingDeadlines.removeValue(forKey: id) }
            for id in expiredPresence { presenceDeadlines.removeValue(forKey: id) }
            changed()
        }
        sendHeldPushes(force: false)
        if localSessionID != transport.myPeerID {
            localSessionID = transport.myPeerID
            helloTimes.removeAll()
        }
        nearby = nearby.filter { connected.contains($0.key) }
        helloTimes = helloTimes.filter { connected.contains($0.key) }
        if tickNumber % 30 == 0 { ingressRate = ingressRate.filter { now().timeIntervalSince($0.value.0) < 60 } }
        if active, foreground { sendPresence(online: true, to: activeContact) }
        // Discovery must recover promptly if the first card raced with the
        // Noise handshake or a republished BLE service. Once authenticated,
        // retain the quiet refresh interval for established neighbors.
        for peer in connected.sorted(by: { $0.id < $1.id }).prefix(20) {
            let interval: TimeInterval = nearby[peer] == nil ? 2 : 30
            guard now().timeIntervalSince(helloTimes[peer] ?? .distantPast) >= interval else { continue }
            helloTimes[peer] = now(); sendPacket(ShumPacket(card: ownCard), to: peer)
        }
        do {
            let ms = Int64(now().timeIntervalSince1970 * 1000)
            if state.relay.contains(where: { $0.envelope.expiresAt <= ms }) || state.receipts.contains(where: { $0.receipt.expiresAt <= ms }) || state.messages.contains(where: { $0.outgoing && [.queued, .forwarding].contains($0.status) && $0.envelope.expiresAt <= ms }) || (state.invitationOutbox ?? []).contains(where: { $0.control.expiresAt <= ms || $0.nostrAccepted || ($0.control.action != .request && $0.attempts >= 6) }) || (tickNumber % 30 == 0 && (state.seenRelay.values.contains(where: { $0 <= now() }) || (state.deletedMessageIDs ?? [:]).values.contains(where: { $0 <= now() }))) {
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
        routeProfiles()
        routeInvitationControls()
        route(\.retractOutbox)
        route(\.reactionOutbox)
        routeOutbox()
        routeRelay()
        routeReceipts()
        if active { markRead() }
    }
    func receiveBytes(_ data: Data, from peer: PeerID) {
        guard data.count <= 24_000, let packet = try? JSONDecoder().decode(ShumPacket.self, from: data) else { return }
        receive(packet, from: peer, nostrSender: nil)
    }
    func receive(_ packet: ShumPacket, from peer: PeerID?, nostrSender: String?) {
        guard !retired else { return }
        if let peer, let key = transport.noiseSessionPublicKeyData(for: peer), state.blocked?[ShumContactCard.userID(key)] != nil { return }
        if let nostrSender, state.blocked?.values.contains(where: { $0.nostrKey == nostrSender }) == true { return }
        if let card = packet.card, isBlocked(card) { return }
        if let envelope = packet.envelope, isBlocked(envelope.sender) || isBlocked(envelope.recipient) { return }
        if let receipt = packet.receipt, isBlocked(receipt.sender) || isBlocked(receipt.destination) { return }
        if let invitation = packet.invitation,
           isBlocked(invitation.sender) || isBlocked(invitation.recipient) { return }
        if let typing = packet.typing,
           isBlocked(typing.sender) || isBlocked(typing.recipient) { return }
        if let presence = packet.presence,
           isBlocked(presence.sender) || isBlocked(presence.recipient) { return }
        if let retract = packet.retract,
           isBlocked(retract.sender) || isBlocked(retract.recipient) { return }
        if let reaction = packet.reaction,
           isBlocked(reaction.sender) || isBlocked(reaction.recipient) { return }
        // Typing/presence and receipt bursts must never spend the delivery
        // budget. Each traffic class remains independently rate-limited.
        let trafficClass = packet.typing != nil || packet.presence != nil
            ? "ephemeral" : (packet.receipt != nil ? "receipt" : "content")
        let source = "\(peer?.id ?? nostrSender ?? "unknown"):\(trafficClass)"
        let old = ingressRate[source] ?? (now(), 0)
        let progress = now().timeIntervalSince(old.0) >= 60 ? (now(), 0) : old
        guard progress.1 < 80, ingressRate.count < 1000 || ingressRate[source] != nil,
              packet.version == 1,
              [packet.card != nil, packet.envelope != nil, packet.receipt != nil,
               packet.invitation != nil, packet.typing != nil, packet.presence != nil, packet.profileSync != nil,
               packet.retract != nil, packet.reaction != nil]
                .filter({ $0 }).count == 1 else { return }
        ingressRate[source] = (progress.0, progress.1 + 1)
        do {
            if let card = packet.card {
                try card.validate()
                guard card.id != ownCard.id else { return }
                if let peer {
                    guard transport.noiseSessionPublicKeyData(for: peer) == card.noiseKey else { return }
                    ShumDiscoveryTrace.record("card-verified")
                    let first = nearby[peer] == nil; nearby[peer] = try mergeProfile(card)
                    if first { sendPacket(ShumPacket(card: ownCard), to: peer) }
                    try recordEncounter(card)
                    if state.contacts.contains(where: { $0.id == card.id }) {
                        try contacts.add(
                            card,
                            source: "nearby",
                            now: now(),
                            includeInAddressBook: false
                        )
                    }
                    changed()
                } else if nostrSender == card.nostrKey {
                    if state.contacts.contains(where: { $0.id == card.id }) { try mergeProfile(card) }
                    else { try request(card) }
                }
            } else if let sync = packet.profileSync {
                try receiveProfile(sync, from: peer, nostrSender: nostrSender)
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
                try receiveInvitation(invitation, avatar: packet.invitationAvatar)
            } else if let typing = packet.typing {
                try receiveTyping(typing, from: peer, nostrSender: nostrSender)
            } else if let presence = packet.presence {
                try receivePresence(presence, from: peer, nostrSender: nostrSender)
            } else if let retract = packet.retract {
                try receiveRetract(retract, from: peer, nostrSender: nostrSender)
            } else if let reaction = packet.reaction {
                try receiveReaction(reaction, from: peer, nostrSender: nostrSender)
            }
        } catch { /* Untrusted invalid packets do not produce modal alerts. */ }
    }
    private func receiveTyping(_ control: ShumTypingControl, from peer: PeerID?, nostrSender: String?) throws {
        try control.validate(at: now())
        guard control.recipient.noiseKey == ownCard.noiseKey,
              control.recipient.signingKey == ownCard.signingKey,
              control.recipient.nostrKey == ownCard.nostrKey else {
            throw ShumFailure.invalidMessage
        }
        if let peer {
            guard transport.noiseSessionPublicKeyData(for: peer) == control.sender.noiseKey else { return }
        }
        if let nostrSender, nostrSender != control.sender.nostrKey { return }
        guard let contact = state.contacts.first(where: { $0.id == control.sender.id }),
              contact.card.signingKey == control.sender.signingKey,
              contact.card.noiseKey == control.sender.noiseKey,
              contact.card.nostrKey == control.sender.nostrKey,
              canMessage(contact.card) else { return }
        try mergeProfile(control.sender)
        if let latest = latestTypingEvents[control.sender.id],
           control.timestamp < latest.timestamp
            || (control.timestamp == latest.timestamp && control.id <= latest.id) { return }
        latestTypingEvents[control.sender.id] = (control.timestamp, control.id)
        if control.isTyping {
            typingDeadlines[control.sender.id] = Date(
                timeIntervalSince1970: Double(control.expiresAt) / 1000
            )
            presenceDeadlines[control.sender.id] = now().addingTimeInterval(
                Double(Self.presenceLifetimeMilliseconds) / 1000
            )
        } else {
            typingDeadlines.removeValue(forKey: control.sender.id)
        }
        changed()
    }
    /// "In chat" is shared only with the contact whose chat is open. Returns
    /// whether a signal was handed to the relay connection.
    @discardableResult
    private func sendPresence(online: Bool, to contactID: String?, completion: (() -> Void)? = nil) -> Bool {
        guard !retired, internet?.connected == true, let contactID,
              let card = state.contacts.first(where: { $0.id == contactID })?.card,
              !isBlocked(card), canMessage(card) else { return false }
        let timestamp = now()
        if online, let last = lastPresenceByContact[contactID],
           timestamp.timeIntervalSince(last) < Self.presenceBroadcastInterval { return false }
        do {
            let milliseconds = max(Int64(timestamp.timeIntervalSince1970 * 1000), lastPresenceMilliseconds + 1)
            lastPresenceMilliseconds = milliseconds
            var control = ShumPresenceControl(
                id: UUID().uuidString,
                sender: ownCard,
                recipient: card,
                isOnline: online,
                timestamp: milliseconds,
                expiresAt: milliseconds + Self.presenceLifetimeMilliseconds
            )
            guard let signature = transport.noiseSignData(try control.signingBytes()) else { return false }
            control.signature = signature
            internet?.send(ShumPacket(presence: control), to: card) { _ in completion?() }
        } catch { return false } // Presence is best effort and never blocks messaging.
        if online { lastPresenceByContact[contactID] = timestamp }
        else { lastPresenceByContact.removeValue(forKey: contactID) }
        return true
    }

    private func receivePresence(_ control: ShumPresenceControl, from peer: PeerID?, nostrSender: String?) throws {
        try control.validate(at: now())
        guard control.recipient.noiseKey == ownCard.noiseKey,
              control.recipient.signingKey == ownCard.signingKey,
              control.recipient.nostrKey == ownCard.nostrKey else {
            throw ShumFailure.invalidMessage
        }
        if let peer {
            guard transport.noiseSessionPublicKeyData(for: peer) == control.sender.noiseKey else { return }
        }
        if let nostrSender, nostrSender != control.sender.nostrKey { return }
        guard let contact = state.contacts.first(where: { $0.id == control.sender.id }),
              contact.card.signingKey == control.sender.signingKey,
              contact.card.noiseKey == control.sender.noiseKey,
              contact.card.nostrKey == control.sender.nostrKey,
              canMessage(contact.card) else { return }
        try mergeProfile(control.sender)
        if let latest = latestPresenceEvents[control.sender.id],
           control.timestamp < latest.timestamp
            || (control.timestamp == latest.timestamp && control.id <= latest.id) { return }
        latestPresenceEvents[control.sender.id] = (control.timestamp, control.id)
        if control.isOnline {
            presenceDeadlines[control.sender.id] = Date(
                timeIntervalSince1970: Double(control.expiresAt) / 1000
            )
        } else {
            presenceDeadlines.removeValue(forKey: control.sender.id)
        }
        changed()
    }
    /// The sender withdrew a message: remove it now or drop it when it arrives.
    private func receiveRetract(_ control: ShumRetractControl, from peer: PeerID?, nostrSender: String?) throws {
        try control.validate(at: now())
        guard control.recipient.noiseKey == ownCard.noiseKey,
              control.recipient.signingKey == ownCard.signingKey,
              control.recipient.nostrKey == ownCard.nostrKey else {
            throw ShumFailure.invalidMessage
        }
        if let peer {
            guard transport.noiseSessionPublicKeyData(for: peer) == control.sender.noiseKey else { return }
        }
        if let nostrSender, nostrSender != control.sender.nostrKey { return }
        guard let contact = state.contacts.first(where: { $0.id == control.sender.id }),
              contact.card.signingKey == control.sender.signingKey,
              contact.card.noiseKey == control.sender.noiseKey else { return }
        let existing = state.messages.first { $0.id == control.messageID }
        if let existing, existing.outgoing || existing.envelope.sender.id != control.sender.id { return }
        let expiry = Date(timeIntervalSince1970: Double(control.expiresAt) / 1000)
        try store.transaction { state in
            if state.deletedMessageIDs == nil { state.deletedMessageIDs = [:] }
            state.deletedMessageIDs?[control.messageID] = expiry
            state.messages.removeAll { $0.id == control.messageID }
            state.receipts.removeAll { $0.receipt.envelopeID == control.messageID }
            state.reactions?.removeValue(forKey: control.messageID)
        }
        if existing != nil { onMessagesRetracted?([control.messageID]) }
        changed()
    }
    /// Keeps the newest reaction of the contact; an older one never overrides it.
    private func receiveReaction(_ control: ShumReactionControl, from peer: PeerID?, nostrSender: String?) throws {
        try control.validate(at: now())
        guard control.recipient.noiseKey == ownCard.noiseKey,
              control.recipient.signingKey == ownCard.signingKey,
              control.recipient.nostrKey == ownCard.nostrKey else {
            throw ShumFailure.invalidMessage
        }
        if let peer {
            guard transport.noiseSessionPublicKeyData(for: peer) == control.sender.noiseKey else { return }
        }
        if let nostrSender, nostrSender != control.sender.nostrKey { return }
        guard let contact = state.contacts.first(where: { $0.id == control.sender.id }),
              contact.card.signingKey == control.sender.signingKey,
              contact.card.noiseKey == control.sender.noiseKey,
              canMessage(contact.card) else { return }
        // A reaction may arrive before its message, but never for another chat.
        if let message = state.messages.first(where: { $0.id == control.messageID }),
           message.envelope.conversationID != ShumConversation.identifier(ownCard.id, control.sender.id) { return }
        if let latest = state.reactions?[control.messageID]?[control.sender.id],
           control.timestamp < latest.timestamp
            || (control.timestamp == latest.timestamp && control.id <= latest.eventID) { return }
        guard state.reactions?[control.messageID] != nil || (state.reactions?.count ?? 0) < 20_000 else { return }
        try store.transaction { state in
            if state.reactions == nil { state.reactions = [:] }
            state.reactions?[control.messageID, default: [:]][control.sender.id] =
                ShumReactionMark(reaction: control.reaction, timestamp: control.timestamp, eventID: control.id)
        }
        changed()
    }
    private func request(_ card: ShumContactCard) throws {
        let card = try mergeProfile(card)
        let phase = invitationPhase(for: card)
        // A legacy card has no action field: it can be a request or the
        // recipient's acceptance after previously declining our request.
        // It may introduce a new person, but must never replace a decision
        // made with signed controls or reverse the invitation's direction.
        guard phase == .ready else { return }
        guard !state.requests.contains(where: { $0.id == card.id }), state.requests.count < 20 else { return }
        let timestamp = Int64(now().timeIntervalSince1970 * 1000)
        try store.transaction { state in
            state.requests.append(card)
            if state.invitationStates == nil { state.invitationStates = [:] }
            state.invitationStates?[card.id] = ShumInvitationState(
                phase: .incomingPending,
                updatedAt: timestamp,
                eventID: "legacy-\(UUID().uuidString)"
            )
            state.invitationOutbox?.removeAll {
                $0.control.recipient.id == card.id
                    && $0.control.action == .request
            }
        }
        changed()
    }
    private func accept(_ envelope: ShumEnvelope, via peer: PeerID?, hop: Int, internet: Bool) throws {
        guard internet || (1...envelope.hopLimit).contains(hop) else { throw ShumFailure.invalidMessage }
        if state.deletedMessageIDs?[envelope.id] != nil { return }
        guard envelope.recipient.noiseKey == ownCard.noiseKey,
              envelope.recipient.signingKey == ownCard.signingKey,
              envelope.recipient.nostrKey == ownCard.nostrKey else { throw ShumFailure.invalidMessage }
        let opened = try crypto.open(envelope.ciphertext)
        guard opened.senderStaticKey == envelope.sender.noiseKey else { throw ShumFailure.invalidMessage }
        let plain = try JSONDecoder().decode(ShumPlaintext.self, from: opened.payload)
        guard [
            ShumWireProtocol.messageName,
            ShumWireProtocol.legacyMessageName
        ].contains(plain.protocolName), plain.id == envelope.id,
              plain.conversationID == envelope.conversationID, plain.senderID == envelope.sender.id,
              plain.recipientID == ownCard.id, plain.timestamp == envelope.timestamp,
              plain.expiresAt == envelope.expiresAt, !plain.text.isEmpty, plain.text.utf8.count <= 4096 else { throw ShumFailure.invalidMessage }
        if let reply = plain.reply {
            guard !reply.messageID.isEmpty, reply.messageID.utf8.count <= 255,
                  !reply.text.isEmpty, reply.text.utf8.count <= 4096,
                  reply.senderID == ownCard.id || reply.senderID == envelope.sender.id else {
                throw ShumFailure.invalidMessage
            }
        }
        guard let contact = state.contacts.first(where: { $0.id == envelope.sender.id }) else {
            try request(envelope.sender); return
        }
        guard contact.card.signingKey == envelope.sender.signingKey, contact.card.nostrKey == envelope.sender.nostrKey else { throw ShumFailure.invalidContact }
        guard canMessage(contact.card) else { return }
        try mergeProfile(envelope.sender)
        if let existing = state.messages.first(where: { $0.id == envelope.id }) {
            guard !existing.outgoing, existing.envelope.digest == envelope.digest else { throw ShumFailure.invalidMessage }
            try makeReceipt(for: existing, read: !existing.unread, force: true); return
        }
        try contacts.conversation(with: contact.card, now: now())
        let visible = foreground && activeContact == contact.id
        let message = ShumStoredMessage(envelope: envelope, text: plain.text, outgoing: false,
            status: .delivered, unread: !visible, hopCount: internet ? 0 : hop,
            deliveryTransport: internet ? "nostr" : (hop > 1 ? "mesh" : "ble"), reply: plain.reply)
        try store.transaction { $0.messages.append(message) }; changed()
        try makeReceipt(for: message, read: visible, force: true)
        if internet { routeReceipts() }
        // Use an already executing Bluetooth background callback to return the
        // durable delivery ACK immediately; never mark background receipt read.
        if let peer, let receipt = state.receipts.first(where: { $0.receipt.envelopeID == message.id })?.receipt {
            sendPacket(ShumPacket(receipt: receipt), to: peer)
        }
    }
    private func carry(_ envelope: ShumEnvelope, hop: Int, depositor: ShumContactCard) throws {
        guard (1..<envelope.hopLimit).contains(hop), !state.seenRelay.keys.contains(envelope.id),
              state.relay.count < 64, state.seenRelay.count < 4000,
              state.relay.filter({ $0.depositor == depositor.id }).count < 8,
              !state.receipts.contains(where: { $0.receipt.envelopeID == envelope.id && $0.receipt.digest == envelope.digest && $0.receipt.sender.id == envelope.recipient.id }) else { return }
        try store.transaction {
            $0.relay.append(ShumRelayCopy(envelope: envelope, hopCount: hop, depositor: depositor.id, forwardedTo: [depositor.id]))
            $0.seenRelay[envelope.id] = Date(timeIntervalSince1970: Double(envelope.expiresAt) / 1000)
        }; changed()
    }
    private func makeReceipt(for message: ShumStoredMessage, read: Bool, force: Bool = false) throws {
        if let existing = state.receipts.first(where: { $0.receipt.envelopeID == message.id && $0.receipt.digest == message.envelope.digest }), existing.receipt.read == read || existing.receipt.read {
            if force, now().timeIntervalSince(existing.lastAttempt) > 10 {
                try store.transaction { state in
                    if let i = state.receipts.firstIndex(where: { $0.receipt.key == existing.receipt.key }) {
                        state.receipts[i].lastAttempt = .distantPast
                        state.receipts[i].sentTo.removeAll()
                        state.receipts[i].nostrAccepted = false
                        state.receipts[i].lastNostrAttempt = nil
                        state.receipts[i].nostrAttempts = nil
                    }
                }
            }
            return
        }
        guard message.envelope.expiresAt > Int64(now().timeIntervalSince1970 * 1000) else { return }
        try acceptReceipt(signedReceipt(for: message, read: read))
    }
    private func signedReceipt(for message: ShumStoredMessage, read: Bool) throws -> ShumReceipt {
        var receipt = ShumReceipt(envelopeID: message.id, digest: message.envelope.digest, sender: ownCard, destination: message.envelope.sender, read: read, timestamp: Int64(now().timeIntervalSince1970 * 1000), expiresAt: message.envelope.expiresAt)
        guard let signature = transport.noiseSignData(try receipt.signingBytes()) else { throw ShumFailure.unavailableIdentity }
        receipt.signature = signature
        return receipt
    }
    private func acceptReceipt(_ receipt: ShumReceipt) throws {
        var next = state
        guard try applyReceipt(receipt, to: &next) else { return }
        try store.transaction { $0 = next }
        if receipt.sender.id != ownCard.id, state.contacts.contains(where: { $0.id == receipt.sender.id }) {
            try mergeProfile(receipt.sender)
        }
        changed()
    }
    /// Reuse the same validation for network receipts and a batch of local reads.
    @discardableResult
    private func applyReceipt(_ receipt: ShumReceipt, to state: inout ShumDatabase) throws -> Bool {
        try receipt.validate(at: now())
        if let i = state.messages.firstIndex(where: { $0.id == receipt.envelopeID && $0.outgoing }) {
            let message = state.messages[i]
            guard message.envelope.digest == receipt.digest, message.envelope.recipient.id == receipt.sender.id,
                  message.envelope.recipient.signingKey == receipt.sender.signingKey, receipt.destination.id == ownCard.id else { throw ShumFailure.invalidMessage }
        }
        let old = state.receipts.first(where: { $0.receipt.key == receipt.key })
        if let old, old.receipt.read || !receipt.read { return false }
        // Only the message's recipient may issue a deletion proof. Carry ACKs
        // along the original carrier graph, not arbitrary unsolicited proofs.
        let original = state.messages.first(where: { $0.id == receipt.envelopeID })?.envelope
            ?? state.relay.first(where: { $0.envelope.id == receipt.envelopeID })?.envelope
        if let original {
            guard original.digest == receipt.digest,
                  original.recipient.id == receipt.sender.id,
                  original.recipient.signingKey == receipt.sender.signingKey,
                  original.sender.id == receipt.destination.id else { return false }
        } else {
            // A verified delivery proof can authenticate a later read upgrade
            // after this courier has already removed the encrypted message.
            guard let previous = old?.receipt, previous.digest == receipt.digest,
                  previous.sender.signingKey == receipt.sender.signingKey,
                  previous.destination.id == receipt.destination.id else { return false }
        }
        guard state.receipts.count < 2000 || old != nil else { return false }
        state.receipts.removeAll { $0.receipt.key == receipt.key }
        state.receipts.append(ShumStoredReceipt(receipt: receipt))
        state.relay.removeAll { $0.envelope.id == receipt.envelopeID && $0.envelope.digest == receipt.digest && $0.envelope.recipient.id == receipt.sender.id && $0.envelope.recipient.signingKey == receipt.sender.signingKey }
        if let i = state.messages.firstIndex(where: { $0.id == receipt.envelopeID && $0.outgoing }) {
            if state.messages[i].status != .read { state.messages[i].status = receipt.read ? .read : .delivered }
            state.messages[i].deliveredAt = Date(timeIntervalSince1970: Double(receipt.timestamp) / 1000)
            if receipt.read { state.messages[i].readAt = state.messages[i].deliveredAt }
        }
        return true
    }
    private func markRead() {
        guard foreground, let activeContact else { return }
        let unread = state.messages.filter {
            !$0.outgoing && $0.envelope.sender.id == activeContact && $0.unread
        }
        guard !unread.isEmpty else { return }
        do {
            var next = state
            for message in unread {
                if message.envelope.expiresAt > Int64(now().timeIntervalSince1970 * 1000),
                   !next.receipts.contains(where: {
                       $0.receipt.envelopeID == message.id && $0.receipt.digest == message.envelope.digest && $0.receipt.read
                   }) {
                    try applyReceipt(signedReceipt(for: message, read: true), to: &next)
                }
            }
            let readIDs = Set(unread.map(\.id))
            for index in next.messages.indices where readIDs.contains(next.messages[index].id) {
                next.messages[index].unread = false
            }
            // Commit the read flags and signed receipts together, once per chat.
            // A failed save leaves both the unread state and outgoing ACKs intact.
            try store.transaction { $0 = next }
            changed()
        } catch { fail(error) }
    }
    private func routeInvitationControls() {
        guard !retired else { return }
        for stored in (state.invitationOutbox ?? []).prefix(4) {
            let control = stored.control
            let direct = session(for: control.recipient)
            let directDelay = min(60.0, 10.0 * pow(2.0, Double(min(max(stored.attempts - 1, 0), 3))))
            let canSendDirect = direct != nil
                && (control.action == .request || stored.attempts < 6)
                && now().timeIntervalSince(stored.lastAttempt) >= directDelay
            let canSendInternet = !stored.nostrAccepted && internet?.connected == true
                && now().timeIntervalSince(stored.lastNostrAttempt ?? .distantPast)
                    >= nostrRetryDelay(stored.nostrAttempts)
            guard canSendDirect || canSendInternet else { continue }

            do {
                try store.transaction { state in
                    guard let index = state.invitationOutbox?.firstIndex(where: { $0.id == stored.id }) else { return }
                    if canSendDirect {
                        state.invitationOutbox?[index].lastAttempt = now()
                        state.invitationOutbox?[index].attempts += 1
                    }
                    if canSendInternet {
                        state.invitationOutbox?[index].lastNostrAttempt = now()
                        state.invitationOutbox?[index].nostrAttempts = (stored.nostrAttempts ?? 0) + 1
                    }
                }
                let packet = ShumPacket(invitation: control)
                if let direct, canSendDirect { sendPacket(packet, to: direct) }
                if canSendInternet {
                    internet?.send(packet, to: control.recipient) { [weak self] accepted in
                        guard let self, accepted, !self.retired else { return }
                        do {
                            try self.store.transaction { state in
                                guard let index = state.invitationOutbox?.firstIndex(where: { $0.id == stored.id }) else { return }
                                state.invitationOutbox?[index].nostrAccepted = true
                            }
                            ShumPushService.shared.notify(
                                recipientID: control.recipient.id,
                                eventID: control.id,
                                kind: .invitation
                            )
                            self.changed()
                        } catch { self.fail(error) }
                    }
                }
                changed()
            } catch { fail(error); return }
        }
    }
    private func routeOutbox() {
        guard !retired else { return }
        var sent = 0
        for message in state.messages.filter({ $0.outgoing && [.queued, .forwarding].contains($0.status) }) {
            if sent >= 4 { break }
            let direct = session(for: message.envelope.recipient)
            let couriers = nearby.filter { $0.value.id != message.envelope.recipient.id && !message.forwardedTo.contains($0.value.id) }.sorted { $0.key.id < $1.key.id }
            let directDue = now().timeIntervalSince(message.lastAttempt)
                >= min(60, 10 * Double(max(1, message.attempts)))
            let canSendDirect = direct != nil && directDue
            let courier = direct == nil && directDue && message.forwardedTo.count < 3
                ? couriers.first : nil
            let canSendInternet = !message.nostrAccepted && internet?.connected == true
                && now().timeIntervalSince(message.lastNostrAttempt ?? .distantPast)
                    >= nostrRetryDelay(message.nostrAttempts)
            guard canSendDirect || courier != nil || canSendInternet else { continue }
            do {
                sent += 1
                try store.transaction { state in
                    guard let i = state.messages.firstIndex(where: { $0.id == message.id }) else { return }
                    if canSendDirect || courier != nil {
                        state.messages[i].attempts += 1
                        state.messages[i].lastAttempt = now()
                    }
                    if let courier { state.messages[i].forwardedTo.insert(courier.value.id) }
                    if canSendInternet {
                        state.messages[i].lastNostrAttempt = now()
                        state.messages[i].nostrAttempts = (message.nostrAttempts ?? 0) + 1
                    }
                    if canSendDirect || courier != nil {
                        state.messages[i].status = .forwarding
                        state.messages[i].deliveryTransport = canSendDirect ? "ble" : "mesh"
                    }
                }
                let packet = ShumPacket(envelope: message.envelope, hopCount: 1)
                if let direct, canSendDirect { sendPacket(packet, to: direct) }
                if let courier { sendPacket(packet, to: courier.key) }
                if canSendInternet {
                    internet?.send(packet, to: message.envelope.recipient) { [weak self] accepted in
                        guard let self, accepted, !self.retired else { return }
                        do {
                            var needsPush = false
                            try self.store.transaction { state in
                                guard let i = state.messages.firstIndex(where: { $0.id == message.id }) else { return }
                                needsPush = [.queued, .forwarding].contains(state.messages[i].status)
                                state.messages[i].nostrAccepted = true
                                if needsPush {
                                    state.messages[i].status = .forwarding
                                    state.messages[i].deliveryTransport = "nostr"
                                }
                            }
                            if needsPush, self.session(for: message.envelope.recipient) != nil {
                                self.heldPushes[message.id] = (message.envelope.recipient.id,
                                    self.now().addingTimeInterval(Self.directDeliveryPushDelay))
                            } else if needsPush {
                                self.requestPush(message.envelope.recipient.id, message.id, .message)
                            }
                            self.changed()
                        } catch { self.fail(error) }
                    }
                }
                changed()
            } catch { fail(error); return }
        }
    }
    /// Repeats withdrawals and reactions until a relay accepts them, a nearby
    /// contact was offered them six times, or they expire.
    private func route<Item: ShumQueuedControl>(_ outbox: WritableKeyPath<ShumDatabase, [Item]?>) {
        guard !retired, let items = state[keyPath: outbox], !items.isEmpty else { return }
        let ms = Int64(now().timeIntervalSince1970 * 1000)
        func finished(_ item: Item) -> Bool { item.expiresAt <= ms || item.nostrAccepted || item.attempts >= 6 }
        do {
            if items.contains(where: finished) {
                try store.transaction { $0[keyPath: outbox]?.removeAll(where: finished) }
            }
            for item in (state[keyPath: outbox] ?? []).prefix(8) {
                let direct = session(for: item.recipient)
                let canSendDirect = direct != nil && now().timeIntervalSince(item.lastAttempt) >= 10
                let canSendInternet = internet?.connected == true
                    && now().timeIntervalSince(item.lastNostrAttempt ?? .distantPast)
                        >= nostrRetryDelay(item.nostrAttempts)
                guard canSendDirect || canSendInternet else { continue }
                try store.transaction { state in
                    guard let i = state[keyPath: outbox]?.firstIndex(where: { $0.id == item.id }) else { return }
                    if canSendDirect {
                        state[keyPath: outbox]?[i].lastAttempt = now()
                        state[keyPath: outbox]?[i].attempts += 1
                    }
                    if canSendInternet {
                        state[keyPath: outbox]?[i].lastNostrAttempt = now()
                        state[keyPath: outbox]?[i].nostrAttempts = (item.nostrAttempts ?? 0) + 1
                    }
                }
                if let direct, canSendDirect { sendPacket(item.packet, to: direct) }
                if canSendInternet {
                    internet?.send(item.packet, to: item.recipient) { [weak self] accepted in
                        guard let self, accepted, !self.retired else { return }
                        do {
                            try self.store.transaction { state in
                                guard let i = state[keyPath: outbox]?.firstIndex(where: { $0.id == item.id }) else { return }
                                state[keyPath: outbox]?[i].nostrAccepted = true
                            }
                        } catch { self.fail(error) }
                    }
                }
            }
        } catch { fail(error) }
    }
    /// Sends a held push only if the Bluetooth delivery did not finish in time.
    private func sendHeldPushes(force: Bool) {
        for (id, held) in heldPushes where force || now() >= held.due {
            heldPushes.removeValue(forKey: id)
            guard let message = state.messages.first(where: { $0.id == id }),
                  [.queued, .forwarding].contains(message.status) else { continue }
            requestPush(held.recipientID, id, .message)
        }
    }
    private func routeRelay() {
        guard !retired else { return }
        var sent = 0
        for copy in state.relay {
            if sent >= 8 { break }
            let direct = session(for: copy.envelope.recipient)
            let next = nearby.filter { !copy.forwardedTo.contains($0.value.id) && $0.value.id != copy.envelope.sender.id && $0.value.id != copy.envelope.recipient.id }.sorted { $0.key.id < $1.key.id }.first
            if let direct, copy.hopCount < copy.envelope.hopLimit, now().timeIntervalSince(copy.lastDirectAttempt) >= 30 {
                sent += 1
                do { try store.transaction { state in if let i = state.relay.firstIndex(where: { $0.envelope.id == copy.envelope.id }) { state.relay[i].lastDirectAttempt = now() } }
                    sendPacket(ShumPacket(envelope: copy.envelope, hopCount: copy.hopCount + 1), to: direct)
                } catch { fail(error) }
            } else if direct == nil, copy.hopCount < copy.envelope.hopLimit, copy.forwardedTo.count < 3, let next {
                sent += 1
                do { try store.transaction { state in if let i = state.relay.firstIndex(where: { $0.envelope.id == copy.envelope.id }) { state.relay[i].forwardedTo.insert(next.value.id) } }
                    sendPacket(ShumPacket(envelope: copy.envelope, hopCount: copy.hopCount + 1), to: next.key)
                } catch { fail(error) }
            }
        }
    }
    private func routeReceipts() {
        guard !retired else { return }
        var sent = 0
        for stored in state.receipts {
            if sent >= 8 { break }
            let receipt = stored.receipt
            let direct = session(for: receipt.destination)
            let next = nearby.filter { !stored.sentTo.contains($0.value.id) && $0.key != direct }.prefix(8)
            let directDue = now().timeIntervalSince(stored.lastAttempt) >= 30
            let useInternet = receipt.sender.id == ownCard.id && !stored.nostrAccepted
                && internet?.connected == true
                && now().timeIntervalSince(stored.lastNostrAttempt ?? .distantPast)
                    >= nostrRetryDelay(stored.nostrAttempts)
            guard (directDue && (direct != nil || !next.isEmpty)) || useInternet else { continue }
            sent += 1
            do {
                try store.transaction { state in if let i = state.receipts.firstIndex(where: { $0.receipt.key == receipt.key }) {
                    if directDue {
                        state.receipts[i].lastAttempt = now()
                        for pair in next { state.receipts[i].sentTo.insert(pair.value.id) }
                    }
                    if useInternet {
                        state.receipts[i].lastNostrAttempt = now()
                        state.receipts[i].nostrAttempts = (stored.nostrAttempts ?? 0) + 1
                    }
                } }
                let packet = ShumPacket(receipt: receipt)
                if directDue {
                    if let direct { sendPacket(packet, to: direct) }
                    for pair in next { sendPacket(packet, to: pair.key) }
                }
                if useInternet { internet?.send(packet, to: receipt.destination) { [weak self] accepted in
                    guard let self, accepted, !self.retired else { return }
                    do { try self.store.transaction { state in if let i = state.receipts.firstIndex(where: { $0.receipt.key == receipt.key }) { state.receipts[i].nostrAccepted = true } } } catch { self.fail(error) }
                } }
            } catch { fail(error) }
        }
    }
    private func nostrRetryDelay(_ attempts: Int?) -> TimeInterval {
        guard let attempts, attempts > 0 else { return 0 }
        return min(60, 5 * pow(2, Double(min(attempts - 1, 4))))
    }
    private func sendPacket(_ packet: ShumPacket, to peer: PeerID) {
        guard !retired, let bytes = try? ShumCoding.encode(packet), bytes.count <= 24_000 else { return }
        wire.sendShumPacket(bytes, to: peer)
    }
    func isBlocked(_ card: ShumContactCard) -> Bool { state.blocked?[card.id] != nil }
    func deleteConversation(with card: ShumContactCard, removeContact: Bool = false) throws {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        let conversationID = ShumConversation.identifier(ownCard.id, card.id)
        try store.transaction { state in
            // Ignore old relay/Nostr replays after local deletion. New messages
            // from a retained contact may create a new conversation.
            if state.deletedMessageIDs == nil { state.deletedMessageIDs = [:] }
            for message in state.messages where message.envelope.conversationID == conversationID {
                let expiry = Date(timeIntervalSince1970: Double(message.envelope.expiresAt) / 1000)
                if expiry > now() { state.deletedMessageIDs?[message.id] = expiry }
                state.reactions?.removeValue(forKey: message.id)
            }
            state.messages.removeAll { $0.envelope.conversationID == conversationID }
            state.reactionOutbox?.removeAll { $0.control.recipient.id == card.id }
            state.legacyHistory?.messages.removeAll { $0.contactID == card.id }
            state.legacyHistory?.contacts.removeAll { $0.id == card.id }
            state.conversations.removeAll { $0.id == conversationID }
            state.receipts.removeAll { $0.receipt.sender.id == card.id || $0.receipt.destination.id == card.id }
            if removeContact {
                state.contacts.removeAll { $0.id == card.id }
                state.requests.removeAll { $0.id == card.id }
                state.invitationStates?.removeValue(forKey: card.id)
                state.invitationOutbox?.removeAll { $0.control.recipient.id == card.id }
                state.profileOutbox?.removeAll { $0.recipientID == card.id }
                for directory in state.pinnedDirectoryEntries?.keys.map({ $0 }) ?? [] {
                    state.pinnedDirectoryEntries?[directory]?.removeAll { $0 == card.id }
                }
            }
        }
        if activeContact == card.id { activeContact = nil }
        changed()
    }
    func clearDirectoryEntry(_ card: ShumContactCard) throws {
        // Clearing is strictly local history removal. Keep the verified
        // contact, encounter and invitation state so an accepted chat remains
        // accepted. deleteConversation does not emit a peer control packet.
        try deleteConversation(with: card)
    }
    func setBlocked(_ card: ShumContactCard, blocked: Bool) throws {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        try card.validate()
        try store.transaction { state in
            if state.blocked == nil { state.blocked = [:] }
            if blocked {
                guard state.blocked!.count < 2000 || state.blocked?[card.id] != nil else { throw ShumFailure.quota }
                state.blocked?[card.id] = card
                state.requests.removeAll { $0.id == card.id }
                state.invitationOutbox?.removeAll { $0.control.recipient.id == card.id }
                state.profileOutbox?.removeAll { $0.recipientID == card.id }
                state.reactionOutbox?.removeAll { $0.control.recipient.id == card.id }
                state.relay.removeAll { $0.envelope.sender.id == card.id || $0.envelope.recipient.id == card.id || $0.depositor == card.id }
                state.receipts.removeAll { $0.receipt.sender.id == card.id || $0.receipt.destination.id == card.id }
                for directory in state.pinnedDirectoryEntries?.keys.map({ $0 }) ?? [] {
                    state.pinnedDirectoryEntries?[directory]?.removeAll { $0 == card.id }
                }
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
        sendPresence(online: false, to: activeContact)
        ShumPushService.shared.clearIdentity(ownCard.id)
        backgroundFetchTask?.cancel()
        backgroundFetchTask = nil
        let pendingFetches = backgroundFetchCompletions
        backgroundFetchCompletions.removeAll()
        for pending in pendingFetches { pending.completion(false) }
        retired = true; foreground = false; activeContact = nil
        heldPushes.removeAll()
        internet?.received = nil; internet?.stop()
        nearby.removeAll(); helloTimes.removeAll(); ingressRate.removeAll()
        typingDeadlines.removeAll(); latestTypingEvents.removeAll(); lastTypingSent.removeAll()
        presenceDeadlines.removeAll(); latestPresenceEvents.removeAll()
        lastPresenceByContact.removeAll()
        presenceFlushID = nil
    }
    private func changed() {
        revision &+= 1
        if !backgroundFetchCompletions.isEmpty {
            Task { @MainActor [weak self] in
                self?.finishReceivedRemoteEvents()
            }
        }
    }
    private func fail(_ error: Error) { onError?(error.localizedDescription) }
}
