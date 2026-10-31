import BitFoundation
import BitLogger
import Combine
import CryptoKit
import CoreBluetooth
import Foundation
import ShumCore
import UIKit

struct ShumPeer: Identifiable, Hashable {
    let id: PeerID
    var name: String
    var lastConnected: Date
}

struct ShumMessage: Identifiable {
    let id: String
    let peerID: PeerID
    let text: String
    let date: Date
    let outgoing: Bool
    var status: DeliveryStatus
    var attempts: Int = 0
    var lastAttempt: Date = .distantPast
    var waitingForConnection = false
    var disconnectedWait: TimeInterval = 0
    var lastProgress: Date = .distantPast
    var deliveryLabel: String?
    var reply: ShumReplyReference? = nil
    var myReaction: ShumReaction? = nil
    var theirReaction: ShumReaction? = nil
    /// Reactions from many people, as in the open chat. When present they
    /// replace the two-person chips above.
    var groupReactions: [ShumGroupReaction] = []
}

struct ShumReactionPerson: Hashable {
    let name: String
    let avatar: Data?
}

/// One reaction and everyone who left it.
struct ShumGroupReaction: Hashable {
    let reaction: ShumReaction
    let people: [ShumReactionPerson]
    /// The user is among them; tapping takes it back.
    let mine: Bool
}

/// Shum on this iPhone: Shum-Core runs the profile, its Bluetooth mesh and
/// its relays; this class shows what Shum-Core stored and passes on what the
/// person does.
@MainActor
final class ShumRuntime: ObservableObject {
    private static var nicknameKey: String { ShumProfileSpace.active.key("shum.nickname") }
    private static let legacyNicknameKey = "spotchat.nickname"
    @Published private(set) var peers: [ShumPeer] = []
    @Published private var nearbyDistances: [PeerID: Int] = [:]
    @Published private(set) var messages: [ShumMessage] = []
    @Published private(set) var unreadMessageIDs: Set<String> = []
    @Published private(set) var nickname: String
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published var error: String?
    @Published private(set) var internetConnected = false
    let profiles: ShumProfiles
    private(set) var permanent: ShumMessageStore?
    private var permanentChanges: AnyCancellable?
    private struct PermanentMessageSnapshot: Equatable {
        var messages: [ShumStoredMessage]
        var reactions: [String: [String: ShumReactionMark]]?
        var history: ShumLegacyArchive?
        var legacyPeers: [String: PeerID]
    }
    private var projectedPermanentMessages: [String: (stored: ShumStoredMessage, message: ShumMessage)] = [:]
    private var permanentMessageSnapshot: PermanentMessageSnapshot?
    @Published private(set) var isLoadingHistory = false
    private var historyLoadingCompletion: Task<Void, Never>?
    private var shouldStartAfterLoading = false
    private var shouldRunTimerAfterLoading = true
    private var setupFailed = false
    private var retired = false
    var onReady: (() -> Void)?
    var deleteProfileHandler: (() -> Void)?
    private var profileChanges: AnyCancellable?
    private(set) var activePeer: PeerID?
    private var appActive = true
    private var bluetoothEnabled = true
    /// The open chat can go out: Bluetooth is allowed here and powered on.
    var bluetoothReady: Bool { bluetoothEnabled && bluetoothState == .poweredOn }
    private var connectedPeerIDs: Set<PeerID> = []
    var isReady: Bool { !setupFailed && !retired && !isLoadingHistory }
    private let defaults: UserDefaults
    private let now: () -> Date
    private var timer: AnyCancellable?
    private var started = false
    private var knownPeers: [PeerID: ShumPeer] = [:]

    /// Opens the profile on Shum-Core. With `deferHistoryLoading` the first
    /// screen appears before Shum-Core has read the database.
    static func live(deferHistoryLoading: Bool = false) -> ShumRuntime {
        let model = ShumRuntime(profileStore: .live())
        let keychain = KeychainManager.makeDefault()
        do {
            let identity = try ShumIdentityService(keychain: keychain, bridge: NostrIdentityBridge(keychain: keychain))
            let card = try identity.card(name: model.nickname, bio: model.profiles.own.bio, avatarSeed: model.profiles.own.avatarSeed)
            guard deferHistoryLoading else {
                model.configurePermanentStore(try coreStore(identity: identity, card: card, name: model.nickname))
                return model
            }
            model.isLoadingHistory = true
            model.historyLoadingCompletion = Task { @MainActor [weak model] in
                await Task.yield()
                guard let model, !model.retired else { return }
                do {
                    let permanent = try coreStore(identity: identity, card: card, name: model.nickname)
                    model.configurePermanentStore(permanent)
                    permanent.setActive(model.appActive)
                    model.isLoadingHistory = false
                    model.onReady?()
                    if model.shouldStartAfterLoading { model.start(runTimer: model.shouldRunTimerAfterLoading) }
                } catch {
                    model.setupFailed = true
                    model.isLoadingHistory = false
                    model.error = error.localizedDescription
                }
            }
        } catch {
            model.setupFailed = true
            model.isLoadingHistory = false
            model.error = error.localizedDescription
        }
        return model
    }

    nonisolated static let sharedCoreRelays = [
        "wss://nostr.oxtr.dev",
        "wss://soloco.nl",
        "wss://relay.snort.social",
        "wss://nostr.bitcoiner.social",
    ]

    /// Shum-Core's session for this profile. A new profile first gets its
    /// database with the signed card, the way a restored backup does.
    static func coreStore(identity: ShumIdentityService, card: ShumContactCard, name: String,
                          database: URL = ShumConversationStore.liveURL,
                          relays: [String] = sharedCoreRelays,
                          push: URL? = ShumRuntime.pushURL) throws -> ShumMessageStore {
        if !FileManager.default.fileExists(atPath: database.path) {
            try createDatabase(identity: identity, card: card, at: database)
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let session = try ShumCoreSession(
            profile: MobileProfile(
                database: database.path,
                id: card.id,
                name: name,
                relays: relays,
                push: push != nil,
                client: "{\"owner\":\"ios\",\"version\":\"\(version)\"}",
                encounterRetentionHours: UInt32(ShumMessageStore.encounterRetention / 3600)
            ),
            keys: identity.coreKeys,
            push: push
        )
        return try ShumMessageStore(core: session, identity: identity)
    }

    /// A new profile's database, holding only its signed card.
    static func createDatabase(identity: ShumIdentityService, card: ShumContactCard, at database: URL) throws {
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        var state: [String: Any] = [
            "version": 1, "ownerID": card.id, "contacts": [], "requests": [], "conversations": [],
            "messages": [], "relay": [], "receipts": [], "seenRelay": [:], "invitationStates": [:],
            "invitationOutbox": [],
        ]
        state["ownProfileCard"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(card))
        try writeDatabase(
            database: database.path,
            ownerId: card.id,
            storage: identity.storageKey.withUnsafeBytes { Data($0) },
            state: String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        )
    }

    /// The push service this build talks to, from its configuration.
    nonisolated static var pushURL: URL? {
        (Bundle.main.object(forInfoDictionaryKey: "ShumPushAPIBaseURL") as? String)
            .flatMap { $0.contains("$(") ? nil : URL(string: $0) }
    }

    private func startRadio() {
        guard let core = permanent?.core else { return }
        core.radioPower = { [weak self] in self?.bluetoothPowered($0) }
        core.startRadio()
    }

    private func stopRadio() {
        permanent?.core.stopRadio()
    }

    private func bluetoothPowered(_ state: CBManagerState) {
        guard !retired else { return }
        bluetoothState = state
        if state != .poweredOn { knownPeers.removeAll(); peers = []; nearbyDistances = [:] }
    }

    func configurePermanentStore(_ store: ShumMessageStore) {
        ShumBackupService.shared.core = store.core
        permanentChanges?.cancel()
        permanentMessageSnapshot = nil
        projectedPermanentMessages.removeAll()
        permanent = store
        store.onError = { [weak self] in self?.error = $0 }
        store.onPresenceFlushFinished = { [weak self] in self?.endPresenceFlushTime() }
        permanentChanges = store.$revision.sink { [weak self] _ in self?.syncPermanentMessages() }
        syncPermanentMessages()
    }

    init(defaults: UserDefaults = .standard,
         profileStore: ShumProfileStore = ShumProfileStore(),
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        let storedName = defaults.string(forKey: Self.nicknameKey)
            ?? (ShumProfileSpace.active.id.isEmpty ? defaults.string(forKey: Self.legacyNicknameKey) : nil)
        if defaults.string(forKey: Self.nicknameKey) == nil,
           let storedName {
            defaults.set(storedName, forKey: Self.nicknameKey)
        }
        let initialName = storedName
            .flatMap(InputValidator.validateNickname) ?? String.localizedFormat("Гость %@".localized, String(UUID().uuidString.prefix(4)))
        profiles = ShumProfiles(name: initialName, store: profileStore)
        nickname = profiles.own.name
        profileChanges = profiles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func waitUntilHistoryLoaded() async {
        await historyLoadingCompletion?.value
    }

    /// Waits until a deferred opening of the profile has finished, so that
    /// a deleted profile's database is never created again.
    func waitForStoragePreparation() async {
        await historyLoadingCompletion?.value
    }

    func retireForDeletion() {
        retired = true; setupFailed = true
        timer?.cancel(); timer = nil
        stopRadio()
        permanent?.retire()
        profiles.retire()
        permanentChanges?.cancel(); profileChanges?.cancel()
        permanentMessageSnapshot = nil
        projectedPermanentMessages.removeAll()
        permanent = nil; messages = []; peers = []; knownPeers = [:]; nearbyDistances = [:]; unreadMessageIDs = []
    }

    func start(runTimer: Bool = true) {
        if isLoadingHistory {
            shouldStartAfterLoading = true; shouldRunTimerAfterLoading = runTimer
            return
        }
        guard !started, !setupFailed, !retired else { return }
        started = true
        if bluetoothEnabled { startRadio() }
        if runTimer {
            timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.tick() }
        }
        tick()
    }

    func setBluetoothEnabled(_ enabled: Bool) {
        guard !retired, bluetoothEnabled != enabled else { return }
        ShumDiscoveryTrace.record(enabled ? "visibility-on" : "visibility-off")
        bluetoothEnabled = enabled
        if isLoadingHistory { return }
        if enabled && started && appActive { startRadio() }
        else if !enabled {
            stopRadio()
            knownPeers.removeAll()
            peers = []
            nearbyDistances = [:]
        }
    }

    func setAppActive(_ active: Bool) {
        guard !retired, !setupFailed else { return }
        guard appActive != active else { return }
        appActive = active
        if isLoadingHistory { return }
        // Ask iOS for a few seconds so the "left chat" signal reaches the relay.
        if !active, permanent != nil { beginPresenceFlushTime() }
        permanent?.setActive(active)
        if active {
            if bluetoothEnabled { startRadio() }
            tick()
        }
    }

    private var presenceFlushTask: UIBackgroundTaskIdentifier = .invalid

    private func beginPresenceFlushTime() {
        guard presenceFlushTask == .invalid else { return }
        presenceFlushTask = UIApplication.shared.beginBackgroundTask(withName: "shum.presence") {
            MainActor.assumeIsolated { [weak self] in self?.endPresenceFlushTime() }
        }
    }

    fileprivate func endPresenceFlushTime() {
        guard presenceFlushTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(presenceFlushTask)
        presenceFlushTask = .invalid
    }

    func fetchRemoteEvents(eventID: String, completion: @escaping (Bool) -> Void) {
        guard !retired, !setupFailed, let permanent else {
            completion(false)
            return
        }
        permanent.fetchRemoteEvents(eventID: eventID, completion: completion)
    }

    func saveNickname(_ name: String) -> Bool {
        guard let valid = InputValidator.validateNickname(name), valid.utf8.count <= 64 else {
            error = "Введите короткое имя без служебных символов.".localized
            return false
        }
        let seed = profiles.own.avatarSeed
            ?? permanent?.ownCard.avatarSeed
            ?? ShumPixelAvatarGenerator.seed(for: Data(valid.utf8))
        return saveProfile(name: valid, bio: profiles.own.bio, avatarSeed: seed)
    }

    func saveProfile(name: String, bio: String, avatarSeed: UInt64) -> Bool {
        guard !retired, let valid = InputValidator.validateNickname(name),
              valid.utf8.count <= 64 else { return false }
        let profile = ShumProfile(name: valid,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
            avatarSeed: avatarSeed).rendered()
        guard profile.valid else { return false }
        do {
            try profiles.save(profile)
            try permanent?.updateProfile(name: profile.name, bio: profile.bio,
                avatarSeed: avatarSeed)
            nickname = valid
            defaults.set(valid, forKey: Self.nicknameKey)
            return true
        } catch { return false }
    }

    func displayName(_ peer: ShumPeer) -> String {
        permanent?.card(for: peer.id)?.name
            ?? permanent?.state.encounters?.first(where: { $0.card.peerID == peer.id })?.card.name
            ?? peers.first(where: { $0.id == peer.id })?.name
            ?? peer.name
    }

    var chatPeers: [ShumPeer] {
        guard let permanent else { return peers }
        let state = permanent.state
        var lastMessageTime: [String: Int64] = [:]
        for message in state.messages {
            let conversationID = message.envelope.conversationID
            lastMessageTime[conversationID] = max(
                lastMessageTime[conversationID] ?? .min,
                message.envelope.timestamp
            )
        }
        var contactsByID: [String: (card: ShumContactCard, addedAt: Date)] = [:]
        for contact in state.contacts where contactsByID[contact.id] == nil {
            contactsByID[contact.id] = (contact.card, contact.addedAt)
        }
        let current: [ShumPeer] = state.conversations.sorted { a, b in
            let aTime = lastMessageTime[a.id] ?? Int64(a.createdAt.timeIntervalSince1970 * 1000)
            let bTime = lastMessageTime[b.id] ?? Int64(b.createdAt.timeIntervalSince1970 * 1000)
            return aTime > bTime
        }.compactMap { conversation in
            guard let contact = contactsByID[conversation.contactID] else { return nil }
            return ShumPeer(id: contact.card.peerID, name: contact.card.name, lastConnected: contact.addedAt)
        }
        let legacy = (state.legacyHistory?.contacts ?? []).filter { old in
            contactsByID[old.id] == nil
        }.map { old in ShumPeer(id: ShumLegacyArchive.peerID(old.id), name: old.name, lastConnected: .distantPast) }
        return current + legacy
    }
    func profile(for peer: PeerID) -> ShumProfile? {
        if let permanent, let card = permanent.card(for: peer) {
            let seed = card.avatarSeed
                ?? ShumPixelAvatarGenerator.seed(for: card.noiseKey)
            return ShumProfile(name: card.name, bio: card.bio,
                avatarSeed: seed).rendered()
        }
        if let encounter = permanent?.state.encounters?.first(where: { $0.card.peerID == peer }) {
            let seed = encounter.card.avatarSeed
                ?? ShumPixelAvatarGenerator.seed(for: encounter.card.noiseKey)
            return ShumProfile(name: encounter.card.name, bio: encounter.card.bio,
                avatarSeed: seed).rendered()
        }
        return nil
    }
    func currentProfileCard(_ card: ShumContactCard) -> ShumContactCard {
        (try? permanent?.contacts.freshest(card)) ?? card
    }
    func addContact(_ card: ShumContactCard, source: String) -> ShumPeer? {
        do {
            guard let permanent else { throw ShumFailure.unavailableIdentity }
            try permanent.add(card, source: source, avatar: nil)
            return ShumPeer(id: card.peerID, name: permanent.card(for: card.peerID)?.name ?? card.name, lastConnected: Date())
        } catch { self.error = error.localizedDescription; return nil }
    }
    func isContact(_ peer: PeerID) -> Bool {
        permanent?.isAddressBookContact(peer) == true
    }
    @discardableResult
    func removeContact(_ card: ShumContactCard) -> Bool {
        do {
            guard let permanent else { throw ShumFailure.unavailableIdentity }
            try permanent.removeFromContacts(card)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    /// A contact from a short link: someone nearby with that Nostr key.
    func resolveContact(
        _ locator: ShumContactLocator,
        completion: @escaping (Result<ShumContactCard, Error>) -> Void
    ) {
        guard let permanent else {
            completion(.failure(ShumFailure.unavailableIdentity))
            return
        }
        if let card = permanent.nearby.values.first(where: { $0.nostrKey == locator.nostrKey }) {
            completion(.success(card))
        } else {
            completion(.failure(ShumFailure.contactUnavailable))
        }
    }
    private func syncPermanentMessages() {
        guard let permanent else { return }
        internetConnected = permanent.internetConnected
        showCoreNearby(permanent)
        var typingSeeds = Set(permanent.typingCards.map { $0.peerID.id })
        if !permanent.publicTypers.isEmpty { typingSeeds.insert(ShumPublicChatView.pixelSeed) }
        ShumTypingPixels.shared.update(typing: typingSeeds)
        let state = permanent.state
        let snapshot = PermanentMessageSnapshot(
            messages: state.messages,
            reactions: state.reactions,
            history: state.legacyHistory,
            legacyPeers: state.legacyHistory == nil ? [:] : Dictionary(
                state.contacts.map { ($0.id, $0.card.peerID) },
                uniquingKeysWith: { first, _ in first }
            )
        )
        // Presence, typing and profile acknowledgements update the directory,
        // but must not rebuild or republish an unchanged conversation history.
        guard snapshot != permanentMessageSnapshot else {
            objectWillChange.send()
            return
        }
        let previousSnapshot = permanentMessageSnapshot
        permanentMessageSnapshot = snapshot
        let ownID = permanent.ownCard.id
        var cardIDs: [Data: String] = [:]
        projectedPermanentMessages.reserveCapacity(state.messages.count)
        var projected = state.messages.map { stored in
            if let cached = projectedPermanentMessages[stored.id], cached.stored == stored,
               previousSnapshot?.reactions?[stored.id] == snapshot.reactions?[stored.id] {
                return cached.message
            }
            let card = stored.outgoing ? stored.envelope.recipient : stored.envelope.sender
            let cardID: String
            if let cached = cardIDs[card.noiseKey] { cardID = cached }
            else { cardID = card.id; cardIDs[card.noiseKey] = cardID }
            let status: DeliveryStatus
            switch stored.status {
            case .queued: status = .sending
            case .forwarding: status = .sent
            case .delivered: status = .delivered(to: card.name, at: stored.deliveredAt ?? Date())
            case .read: status = .read(by: card.name, at: stored.readAt ?? Date())
            case .expired: status = .failed(reason: "Срок доставки истёк".localized)
            case .cancelled: status = .failed(reason: "Отменено после блокировки".localized)
            }
            let message = ShumMessage(id: stored.id, peerID: card.peerID, text: stored.text,
                date: Date(timeIntervalSince1970: Double(stored.envelope.timestamp) / 1000), outgoing: stored.outgoing,
                status: status, attempts: stored.attempts,
                deliveryLabel: stored.status == .forwarding && stored.deliveryTransport == "mesh" ? "Передаётся через mesh".localized : stored.status.label,
                reply: stored.reply,
                myReaction: permanent.reaction(of: ownID, on: stored.id),
                theirReaction: permanent.reaction(of: cardID, on: stored.id))
            projectedPermanentMessages[stored.id] = (stored, message)
            return message
        }
        if let history = state.legacyHistory {
            projected += history.messages.map { old in
                let peer = snapshot.legacyPeers[old.contactID] ?? ShumLegacyArchive.peerID(old.contactID)
                return ShumMessage(id: "legacy-" + old.id, peerID: peer, text: old.text, date: old.date,
                    outgoing: old.outgoing, status: old.status, deliveryLabel: "История".localized)
            }
            projected.sort { $0.date < $1.date }
        }
        if projectedPermanentMessages.count > state.messages.count {
            let currentIDs = Set(state.messages.map(\.id))
            projectedPermanentMessages = projectedPermanentMessages.filter { currentIDs.contains($0.key) }
        }
        messages = projected
        let unread = Set(state.messages.filter { $0.unread }.map { "\($0.envelope.sender.peerID.id):\($0.id)" })
        if unreadMessageIDs != unread { unreadMessageIDs = unread }
    }

    func openConversation(_ peer: PeerID?) {
        activePeer = peer
        guard let permanent else { return }
        permanent.open(peer.flatMap { permanent.card(for: $0) })
    }

    /// A chat may report disappearing after the next chat appeared; only the
    /// chat that is still open is closed.
    func closeConversation(_ peer: PeerID) {
        guard activePeer == peer else { return }
        if let permanent, let card = permanent.card(for: peer) {
            activePeer = nil
            permanent.close(card)
            return
        }
        openConversation(nil)
    }

    func isLegacyOnly(_ peer: PeerID) -> Bool { peer.id.hasPrefix("legacy-") }

    func chatProtection(for peer: PeerID) -> ShumChatProtectionState {
        ShumChatProtectionState(
            isReady: isReady,
            isArchive: isLegacyOnly(peer),
            hasRecipientKey: permanent?.card(for: peer) != nil
        )
    }

    func conversation(_ peer: PeerID) -> [ShumMessage] {
        messages.filter { $0.peerID == peer }
    }

    func unreadCount(for peer: PeerID) -> Int {
        conversation(peer).filter { !$0.outgoing && unreadMessageIDs.contains("\(peer.id):\($0.id)") }.count
    }

    func isBlocked(_ peer: PeerID) -> Bool {
        guard let permanent, let card = permanent.card(for: peer) else { return false }
        return permanent.isBlocked(card)
    }
    func invitationPhase(for peer: PeerID) -> ShumInvitationPhase {
        #if DEBUG && targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ShumPreviewInvitationReady") { return .ready }
        if arguments.contains("-ShumPreviewInvitationSent") { return .outgoingPending }
        if arguments.contains("-ShumPreviewInvitationReceived") { return .incomingPending }
        if arguments.contains("-ShumPreviewInvitationDeclined") { return .declinedByPeer }
        if arguments.contains("-ShumPreviewInvitationRecover") { return .declinedLocally }
        #endif
        guard let permanent else { return .accepted }
        guard let card = permanent.card(for: peer) else { return .ready }
        return permanent.invitationPhase(for: card)
    }
    @discardableResult
    func sendInvitation(to peer: PeerID) -> Bool {
        guard let permanent, let card = permanent.card(for: peer) else {
            error = "Дождитесь проверки профиля собеседника.".localized
            return false
        }
        return permanent.sendInvitation(card)
    }
    @discardableResult
    func acceptInvitation(from peer: PeerID) -> Bool {
        guard let permanent, let card = permanent.card(for: peer) else { return false }
        return permanent.acceptInvitation(card)
    }
    @discardableResult
    func declineInvitation(from peer: PeerID) -> Bool {
        guard let permanent, let card = permanent.card(for: peer) else { return false }
        return permanent.declineInvitation(card)
    }
    func isNearby(_ peer: PeerID) -> Bool {
        guard bluetoothState == .poweredOn else { return false }
        guard let permanent, let card = permanent.card(for: peer) else { return false }
        return permanent.session(for: card) != nil
    }

    func isTyping(_ peer: PeerID) -> Bool {
        guard let permanent, let card = permanent.card(for: peer) else { return false }
        return permanent.isTyping(card)
    }

    func isInChat(_ peer: PeerID) -> Bool {
        guard let permanent, let card = permanent.card(for: peer) else { return false }
        return permanent.isInChat(card)
    }

    func setTyping(_ active: Bool, for peer: PeerID) {
        guard let permanent, let card = permanent.card(for: peer) else { return }
        permanent.setTyping(active, for: card)
    }

    func distanceMeters(for peer: PeerID) -> Int? {
        guard isNearby(peer) else { return nil }
        return nearbyDistances[peer]
    }

    @discardableResult
    func send(_ text: String, to peer: PeerID, replyingTo original: ShumMessage? = nil) -> Bool {
        guard isReady, let permanent else { return false }
        guard let card = permanent.card(for: peer) else { error = "Дождитесь проверки профиля собеседника.".localized; return false }
        let reply = original.map {
            ShumReplyReference(messageID: $0.id,
                senderID: $0.outgoing ? permanent.ownCard.id : card.id,
                text: $0.text)
        }
        return permanent.send(text, to: card, reply: reply)
    }

    /// Sets the user's one reaction on a message; the same reaction again takes it back.
    func toggleReaction(_ reaction: ShumReaction, on message: ShumMessage) {
        permanent?.toggleReaction(reaction, on: message.id)
    }

    /// Withdraws a message that has not reached the contact yet.
    func cancelSending(_ message: ShumMessage) {
        guard message.outgoing, let permanent else { return }
        permanent.cancelSending(message.id)
    }

    func retry(_ message: ShumMessage) {
        guard let permanent, let card = permanent.card(for: message.peerID),
              case .failed = message.status else { return }
        permanent.resend(message.id, to: card)
    }

    func tick() {
        guard !isLoadingHistory, !retired, let permanent else { return }
        internetConnected = permanent.internetConnected
        showCoreNearby(permanent)
    }

    /// People nearby as Shum-Core's mesh sees them. Shum-Core already waits
    /// a moment before someone counts as gone.
    private func showCoreNearby(_ permanent: ShumMessageStore) {
        let on = bluetoothEnabled && bluetoothState == .poweredOn
        let cards = on ? permanent.nearby.values.filter { !permanent.isBlocked($0) } : []
        let ids = Set(cards.map(\.peerID))
        if connectedPeerIDs != ids { ShumDiscoveryTrace.record("runtime-connected-count-\(ids.count)") }
        connectedPeerIDs = ids
        let distances = Dictionary(cards.compactMap { card in
            permanent.distance(for: card).flatMap { $0 > 0 ? (card.peerID, $0) : nil }
        }, uniquingKeysWith: { _, latest in latest })
        if nearbyDistances != distances { nearbyDistances = distances }
        let current = now()
        let found: [ShumPeer] = cards.map { (card: ShumContactCard) -> ShumPeer in
            let since: Date = knownPeers[card.peerID]?.lastConnected ?? current
            return ShumPeer(id: card.peerID, name: card.name, lastConnected: since)
        }
        let next = found.sorted { (a: ShumPeer, b: ShumPeer) -> Bool in
            a.name == b.name ? a.id.id < b.id.id : a.name < b.name
        }
        knownPeers = Dictionary(next.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if peers != next { peers = next }
    }
}
