import BitFoundation
import Combine
import Foundation
import ShumCore

/// A note in the open chat with everyone nearby, as Shum-Core keeps it for a day.
struct ShumPublicNote: Identifiable, Equatable {
    /// The author and the note's own ID: two people may pick the same one.
    var id: String { "\(card.id):\(noteID)" }
    let noteID: String
    let card: ShumContactCard
    let text: String
    let date: Date
    let outgoing: Bool
    var reply: ShumReplyReference?
    var reactions: [ShumPublicReaction] = []
}

/// One person's reaction on an open-chat note.
struct ShumPublicReaction: Equatable {
    let personID: String
    let reaction: ShumReaction
    let card: ShumContactCard?
}

/// The profile as Shum-Core runs it, the core every Shum client shares.
/// Screens read Shum-Core's stored state and snapshot from here; every change
/// becomes a request to Shum-Core, which alone writes the database.
@MainActor
final class ShumMessageStore: ObservableObject {
    static let encounterRetention: TimeInterval = 24 * 60 * 60
    @Published private(set) var revision = 0
    let store: ShumConversationStore
    let contacts: ShumContactsService
    let core: ShumCoreSession
    private let now: () -> Date
    private(set) var ownCard: ShumContactCard
    var onError: ((String) -> Void)?
    /// Lets the app release the background time it requested for "left chat".
    var onPresenceFlushFinished: (() -> Void)?
    /// People nearby by card, as Shum-Core's Bluetooth mesh sees them.
    private(set) var nearby: [PeerID: ShumContactCard] = [:]
    /// People as Shum-Core's snapshot shows them, for typing, "in chat" and distance.
    private var people: [String: [String: Any]] = [:]
    private(set) var internetConnected = false
    /// The day's open chat, oldest first.
    private(set) var publicNotes: [ShumPublicNote] = []
    /// Everyone on the Bluetooth mesh, near or relayed, by card.
    private(set) var meshPeople: [ShumContactCard] = []
    /// Who is typing in the open chat right now.
    private(set) var publicTypers: [ShumContactCard] = []
    /// Who has the open chat on screen right now.
    private(set) var publicPeople: [ShumContactCard] = []
    /// The last own typing signal in the open chat, as for a contact.
    private var publicTypingSent: (active: Bool, at: Date)?
    /// What screens last showed of people nearby, typing and "in chat".
    private var shownPeople = ""
    /// The last typing signal per contact, so it goes out on a start or a
    /// stop and while typing at most every four seconds.
    private var typingSent: [String: (active: Bool, at: Date)] = [:]
    private var retired = false

    init(core: ShumCoreSession, identity: ShumIdentityService, now: @escaping () -> Date = Date.init) throws {
        let state = try Self.decodeCoreState(core.state())
        guard let card = state.ownProfileCard else { throw ShumFailure.unavailableIdentity }
        store = ShumConversationStore(coreState: state)
        contacts = ShumContactsService(store: store)
        self.core = core
        self.now = now
        ownCard = card
        core.changed = { [weak self] stored in self?.coreChanged(stored: stored) }
        show(state: .success(state), snapshot: core.snapshot())
        ShumPushService.shared.configure(card: ownCard) { [weak identity] data in
            identity?.sign(data)
        }
    }

    var state: ShumDatabase { store.state }

    /// Decodes the state Shum-Core stored: the section 09 layout, dates as
    /// seconds since 2001.
    nonisolated static func decodeCoreState(_ json: String) throws -> ShumDatabase {
        try JSONDecoder().decode(ShumDatabase.self, from: Data(json.utf8))
    }

    var encounterHistory: [ShumEncounter] {
        (state.encounters ?? [])
            .filter {
                !isBlocked($0.card)
                    && $0.lastSeen >= now().addingTimeInterval(-Self.encounterRetention)
            }
            .sorted { $0.lastSeen > $1.lastSeen }
    }
    var unviewedEncounterCount: Int { unviewedEncounterIDs.count }
    var unviewedEncounterIDs: Set<String> {
        let visibleIDs = Set(encounterHistory.map(\.id))
        return (state.unviewedEncounterIDs ?? []).intersection(visibleIDs)
    }

    /// A push woke the app: Shum-Core's relays deliver what it announced.
    /// Completes with true once that event is stored, or false after 20 s.
    func fetchRemoteEvents(eventID: String, completion: @escaping (Bool) -> Void) {
        guard !retired else { return completion(false) }
        core.wake()
        Task { @MainActor [weak self] in
            for _ in 0..<80 {
                if self?.containsRemoteEvent(eventID) == true { return completion(true) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            completion(false)
        }
    }
    private func containsRemoteEvent(_ eventID: String) -> Bool {
        state.messages.contains { !$0.outgoing && $0.id == eventID }
            || state.reactions?[eventID]?.contains { $0.key != ownCard.id && $0.value.reaction != nil } == true
            || state.invitationStates?.values.contains { $0.eventID == eventID } == true
    }

    func setActive(_ active: Bool) {
        guard !retired else { return }
        if active {
            core.wake()
            return
        }
        // Leaving the app ends "in chat"; the session sends that right away.
        request(["command": "focus", "contact": NSNull()])
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.onPresenceFlushFinished?()
        }
    }

    func updateProfile(name: String, bio: String, avatarSeed: UInt64? = nil) throws {
        var request: [String: Any] = ["command": "profile", "name": name, "bio": bio]
        request["seed"] = avatarSeed.map { NSNumber(value: $0) } ?? NSNull()
        self.request(request)
    }

    func card(for peer: PeerID) -> ShumContactCard? {
        state.contacts.first(where: { $0.card.peerID == peer })?.card
            ?? nearby[peer]
            ?? state.encounters?.first(where: { $0.card.peerID == peer })?.card
            ?? state.requests.first(where: { $0.peerID == peer })
            ?? state.blocked?.values.first(where: { $0.peerID == peer })
    }
    /// Whether `card` is nearby over Bluetooth, by its peer ID.
    func session(for card: ShumContactCard) -> PeerID? {
        nearby[card.peerID]?.id == card.id ? card.peerID : nil
    }
    /// Metres to someone nearby, as Shum-Core estimates it from the signal.
    func distance(for card: ShumContactCard) -> Int? {
        (people[card.id]?["distance"] as? NSNumber)?.intValue
    }
    func avatar(for card: ShumContactCard) -> Data? {
        state.invitationStates?[card.id]?.avatar
            ?? state.contacts.first(where: { $0.id == card.id })?.avatar
            ?? state.encounters?.first(where: { $0.id == card.id })?.avatar
    }

    func add(_ card: ShumContactCard, source _: String, avatar _: Data? = nil) throws {
        request(["command": "add", "link": try card.invitation().absoluteString])
    }
    func isAddressBookContact(_ card: ShumContactCard) -> Bool {
        state.contacts.first(where: { $0.id == card.id })?.isAddressBookEntry == true
    }
    func isAddressBookContact(_ peer: PeerID) -> Bool {
        state.contacts.first(where: { $0.card.peerID == peer })?.isAddressBookEntry == true
    }
    func removeFromContacts(_ card: ShumContactCard) throws {
        request(["command": "remove_contact", "contact": card.id])
    }
    func dismissRequest(_ card: ShumContactCard) {
        declineInvitation(card)
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
        people[card.id]?["typing"] as? Bool == true
    }
    /// Contacts currently typing to this device.
    var typingCards: [ShumContactCard] {
        state.contacts.map(\.card).filter { isTyping($0) }
    }
    /// The contact has this conversation open, per its signed presence.
    func isInChat(_ card: ShumContactCard) -> Bool {
        people[card.id]?["online"] as? Bool == true
    }
    func setTyping(_ active: Bool, for card: ShumContactCard) {
        let last = typingSent[card.id]
        if last.map({ $0.active == active && (!active || now().timeIntervalSince($0.at) < 4) }) ?? !active { return }
        typingSent[card.id] = (active, now())
        request(["command": "typing", "contact": card.id, "active": active])
    }
    @discardableResult
    func sendInvitation(_ card: ShumContactCard) -> Bool {
        request(["command": "invite", "contact": card.id])
        return true
    }
    @discardableResult
    func acceptInvitation(_ card: ShumContactCard) -> Bool {
        request(["command": "accept", "contact": card.id])
        return true
    }
    @discardableResult
    func declineInvitation(_ card: ShumContactCard) -> Bool {
        request(["command": "decline", "contact": card.id])
        return true
    }

    /// The chat on screen, which also tells the contact "in chat".
    func open(_ card: ShumContactCard?) {
        request(["command": "focus", "contact": card?.id ?? NSNull()])
    }
    func close(_: ShumContactCard) {
        request(["command": "focus", "contact": NSNull()])
    }

    func markEncountersViewed() {
        request(["command": "view_encounters", "contact": NSNull()])
    }
    func markEncounterViewed(_ id: String) {
        request(["command": "view_encounters", "contact": id])
    }
    func isPinned(_ card: ShumContactCard, in directory: String) -> Bool {
        state.pinnedDirectoryEntries?[directory]?.contains(card.id) == true
    }
    func pinnedCardIDs(in directory: String) -> [String] {
        state.pinnedDirectoryEntries?[directory] ?? []
    }
    @discardableResult
    func togglePinned(_ card: ShumContactCard, in directory: String) throws -> Bool {
        let pinned = !isPinned(card, in: directory)
        request(["command": "pin", "contact": card.id, "directory": directory])
        return pinned
    }
    func deleteEncounter(_ card: ShumContactCard) {
        request(["command": "delete_encounters", "contact": card.id])
    }
    func clearEncounters() {
        request(["command": "delete_encounters", "contact": NSNull()])
    }

    private var publicSeenKey: String { "shum.publicChat.seen.\(ownCard.id)" }
    /// Notes from others since the open chat was last on screen here.
    var publicUnread: Int {
        let seen = UserDefaults.standard.double(forKey: publicSeenKey)
        return publicNotes.filter { !$0.outgoing && $0.date.timeIntervalSince1970 > seen }.count
    }
    /// The open chat is on screen: everything in it counts as read.
    func markPublicChatRead() {
        guard let last = publicNotes.last?.date.timeIntervalSince1970,
              last > UserDefaults.standard.double(forKey: publicSeenKey) else { return }
        UserDefaults.standard.set(last, forKey: publicSeenKey)
        revision &+= 1
    }

    /// Writes to the open chat; everyone on the Bluetooth mesh reads it.
    func broadcast(_ text: String, reply: ShumReplyReference? = nil) {
        var request: [String: Any] = ["command": "broadcast", "text": text]
        if let reply {
            request["reply"] = ["messageID": reply.messageID, "senderID": reply.senderID, "text": reply.text]
        }
        self.request(request)
    }
    /// Sets the user's reaction on an open-chat note; nil takes it back.
    func publicReaction(_ reaction: ShumReaction?, on note: ShumPublicNote) {
        var request: [String: Any] = ["command": "public_reaction", "note": note.noteID, "author": note.card.id]
        if let reaction { request["reaction"] = reaction.rawValue }
        self.request(request)
    }
    /// Tells everyone nearby that the user types in the open chat, on a
    /// start or a stop and while typing at most every four seconds.
    func setPublicTyping(_ active: Bool) {
        let last = publicTypingSent
        if last.map({ $0.active == active && (!active || now().timeIntervalSince($0.at) < 4) }) ?? !active { return }
        publicTypingSent = (active, now())
        request(["command": "public_typing", "active": active])
    }
    /// The open chat came on screen or left it; Shum-Core tells everyone
    /// nearby and repeats it while the chat stays open.
    func setPublicPresence(_ online: Bool) {
        request(["command": "public_presence", "online": online])
    }
    /// Withdraws the user's own note from everyone in the open chat.
    func publicRetract(_ note: ShumPublicNote) {
        request(["command": "public_retract", "note": note.noteID])
    }

    func send(_ text: String, to card: ShumContactCard, reply: ShumReplyReference? = nil) -> Bool {
        var request: [String: Any] = ["command": "send", "contact": card.id, "text": text]
        if let reply {
            request["reply"] = ["messageID": reply.messageID, "senderID": reply.senderID, "text": reply.text]
        }
        self.request(request)
        return true
    }
    /// Sends an expired message again.
    @discardableResult
    func resend(_ messageID: String, to _: ShumContactCard) -> Bool {
        guard state.messages.contains(where: { $0.id == messageID && $0.outgoing && $0.status == .expired }) else { return false }
        request(["command": "resend", "message": messageID])
        return true
    }
    func reaction(of personID: String, on messageID: String) -> ShumReaction? {
        state.reactions?[messageID]?[personID]?.reaction
    }
    /// Sets the user's single reaction on a message. Choosing the reaction that
    /// is already there takes it back. The contact gets it without a push.
    @discardableResult
    func toggleReaction(_ reaction: ShumReaction, on messageID: String) -> Bool {
        request(["command": "reaction", "message": messageID, "reaction": reaction.rawValue])
        return true
    }
    /// Withdraws a message that has not reached the contact yet.
    @discardableResult
    func cancelSending(_ messageID: String) -> Bool {
        request(["command": "cancel", "message": messageID])
        return true
    }

    func isBlocked(_ card: ShumContactCard) -> Bool { state.blocked?[card.id] != nil }
    func deleteConversation(with card: ShumContactCard, removeContact: Bool = false) throws {
        request(["command": "clear", "contact": card.id])
        if removeContact { request(["command": "remove_contact", "contact": card.id]) }
    }
    /// Removes the local history only; the contact and the accepted chat stay.
    func clearDirectoryEntry(_ card: ShumContactCard) throws {
        try deleteConversation(with: card)
    }
    func setBlocked(_ card: ShumContactCard, blocked: Bool) throws {
        request(["command": "block", "contact": card.id, "blocked": blocked])
    }

    /// The profile is being deleted: nothing may save or send any more.
    func retire() {
        guard !retired else { return }
        retired = true
        core.close()
        ShumPushService.shared.clearIdentity(ownCard.id)
        nearby.removeAll()
        people.removeAll()
    }

    /// Shum-Core changed something: read its snapshot, and its stored state
    /// when it stored something, off the main thread.
    private func coreChanged(stored: Bool) {
        guard !retired else { return }
        core.read(stored: stored) { [weak self] state, snapshot in
            self?.show(state: state, snapshot: snapshot)
        }
    }

    /// Shows a new stored state and who is nearby, typing and in chat.
    /// Screens redraw only when something they show changed.
    private func show(state: Result<ShumDatabase, Error>?, snapshot: [String: Any]) {
        guard !retired else { return }
        switch state {
        case .success(let next):
            store.adopt(next)
            if let card = next.ownProfileCard { ownCard = card }
        case .failure(let error):
            fail(error)
        case nil:
            break
        }
        var people: [String: [String: Any]] = [:]
        var found: [PeerID: ShumContactCard] = [:]
        var mesh: [ShumContactCard] = []
        for contact in snapshot["contacts"] as? [[String: Any]] ?? [] {
            guard let id = contact["id"] as? String else { continue }
            people[id] = contact
            guard contact["nearby"] as? Bool == true || contact["mesh"] as? Bool == true,
                  let card = Self.card(contact["card"]) else { continue }
            mesh.append(card)
            if contact["nearby"] as? Bool == true { found[card.peerID] = card }
        }
        let notes: [ShumPublicNote] = (snapshot["publicChat"] as? [[String: Any]] ?? []).compactMap { note in
            guard let noteID = note["id"] as? String, let text = note["text"] as? String,
                  let card = Self.card(note["card"]),
                  let timestamp = (note["timestamp"] as? NSNumber)?.doubleValue else { return nil }
            let reply = (note["reply"] as? [String: Any]).flatMap { reply -> ShumReplyReference? in
                guard let messageID = reply["messageID"] as? String, let senderID = reply["senderID"] as? String,
                      let text = reply["text"] as? String else { return nil }
                return ShumReplyReference(messageID: messageID, senderID: senderID, text: text)
            }
            let reactions = (note["reactions"] as? [[String: Any]] ?? []).compactMap { mark -> ShumPublicReaction? in
                guard let person = mark["personID"] as? String,
                      let reaction = (mark["reaction"] as? String).flatMap(ShumReaction.init(rawValue:)) else { return nil }
                return ShumPublicReaction(personID: person, reaction: reaction, card: Self.card(mark["card"]))
            }
            return ShumPublicNote(noteID: noteID, card: card, text: text,
                                  date: Date(timeIntervalSince1970: timestamp / 1000),
                                  outgoing: note["outgoing"] as? Bool == true,
                                  reply: reply, reactions: reactions)
        }
        var noteHash = Hasher()
        for note in notes {
            noteHash.combine(note.id)
            for mark in note.reactions {
                noteHash.combine(mark.personID)
                noteHash.combine(mark.reaction.rawValue)
            }
        }
        let typers = (snapshot["publicTyping"] as? [Any] ?? []).compactMap(Self.card)
        let present = (snapshot["publicPresent"] as? [Any] ?? []).compactMap(Self.card)
        let internet = !(snapshot["relays"] as? [Any] ?? []).isEmpty
        let shown = people.keys.sorted().map { id -> String in
            let person = people[id] ?? [:]
            return "\(id):\(person["nearby"] ?? ""):\(person["distance"] ?? ""):\(person["typing"] ?? ""):\(person["online"] ?? "")"
        }.joined(separator: ",") + "|\(internet)|\(notes.count):\(noteHash.finalize())|\(mesh.map(\.id).sorted())|\(typers.map(\.id).sorted())|\(present.map(\.id).sorted())"
        guard state != nil || shown != shownPeople else { return }
        shownPeople = shown
        self.people = people
        nearby = found
        meshPeople = mesh
        publicTypers = typers
        publicPeople = present
        publicNotes = notes
        internetConnected = internet
        revision &+= 1
    }

    /// Sends a request to Shum-Core; a failure reaches the person as an error.
    private func request(_ request: [String: Any]) {
        guard !retired else { return }
        Task { @MainActor [weak self, core] in
            do { _ = try await core.request(request) } catch { self?.fail(error) }
        }
    }

    private func fail(_ error: Error) { onError?(error.localizedDescription) }

    private static func card(_ value: Any?) -> ShumContactCard? {
        value.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(ShumContactCard.self, from: $0) }
    }
}
