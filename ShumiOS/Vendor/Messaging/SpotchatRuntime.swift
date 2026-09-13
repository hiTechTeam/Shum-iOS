import BitFoundation
import Combine
import CryptoKit
import CoreBluetooth
import Foundation

struct SpotchatPeer: Identifiable, Hashable {
    let id: PeerID
    var name: String
    var lastConnected: Date
}

struct SpotchatMessage: Identifiable {
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
}

/// Spotchat composition. Radio/session management stays inside the transport;
/// permanent identity, history and routing belong to the application services.
@MainActor
final class SpotchatRuntime: ObservableObject, TransportEventDelegate, TransportPeerEventsDelegate {
    @Published private(set) var peers: [SpotchatPeer] = []
    @Published private var nearbyDistances: [PeerID: Int] = [:]
    @Published private(set) var messages: [SpotchatMessage] = []
    @Published private var unreadMessageIDs: Set<String> = []
    @Published private(set) var nickname: String
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published var error: String?
    @Published private(set) var internetConnected = false
    let profiles: SpotchatProfiles
    private(set) var permanent: SpotchatMessageStore?
    private var permanentChanges: AnyCancellable?
    private var setupFailed = false
    private var retired = false
    var deleteProfileHandler: (() -> Void)?
    private var profileChanges: AnyCancellable?
    private(set) var activePeer: PeerID?
    private var appActive = true
    private var bluetoothEnabled = true
    var isReady: Bool { !setupFailed && !retired }
    private var readAttempts: [String: (count: Int, sentAt: Date)] = [:]
    private let transport: Transport
    private let defaults: UserDefaults
    private let now: () -> Date
    private var timer: AnyCancellable?
    private var started = false
    private var knownPeers: [PeerID: SpotchatPeer] = [:]
    private var receivedIDs: Set<String> = []
    private var receivedOrder: [String] = []
    static let disappearanceDelay: TimeInterval = 6
    static let retryInterval: TimeInterval = 10
    static let maxAttempts = 3
    static let connectionWaitLimit: TimeInterval = 120

    static func live() -> SpotchatRuntime {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-ShumPreview") { return preview() }
        #endif
        let keychain = KeychainManager.makeDefault()
        let ble = BLEService(keychain: keychain,
                             idBridge: NostrIdentityBridge(keychain: keychain),
                             identityManager: SecureIdentityStateManager(keychain))
        let model = SpotchatRuntime(transport: ble, profileStore: .live())
        // Legacy synthetic radio diagnostics remain isolated from real history.
        if UserDefaults.standard.string(forKey: "ShumSelfTestRun") == nil {
            do {
                let identity = try SpotchatIdentityService(transport: ble, keychain: keychain, bridge: NostrIdentityBridge(keychain: keychain))
                let card = try identity.card(name: model.nickname, bio: model.profiles.own.bio)
                var preview = false
                #if DEBUG && targetEnvironment(simulator)
                preview = ProcessInfo.processInfo.arguments.contains("-ShumPermanentPreview")
                #endif
                let store = try SpotchatConversationStore(ownerID: card.id, key: identity.storageKey, url: preview ? nil : SpotchatConversationStore.liveURL)
                if !preview { try ShumHistoryMigration.live(into: store) }
                let internet = preview ? nil : SpotchatNostrService(identity: identity.nostr, manager: .spotchat())
                let permanent = SpotchatMessageStore(identity: identity, store: store, transport: ble, wire: ble, card: card, internet: internet)
                model.permanent = permanent
                permanent.onError = { [weak model] in model?.error = $0 }
                model.permanentChanges = permanent.$revision.sink { [weak model] _ in model?.syncPermanentMessages() }
                #if DEBUG && targetEnvironment(simulator)
                if preview { try model.seedPermanentPreview() }
                #endif
                model.syncPermanentMessages()
            } catch { model.setupFailed = true; model.error = error.localizedDescription }
        }
        return model
    }

    #if DEBUG && targetEnvironment(simulator)
    private static func preview() -> SpotchatRuntime {
        let wire = SpotchatPreviewTransport()
        let model = SpotchatRuntime(transport: wire, defaults: UserDefaults(suiteName: "Shum.UI.Preview")!)
        model.nickname = "Руслан"
        try? model.profiles.save(SpotchatProfile(name: "Руслан", bio: "Люблю знакомиться и создавать новое"))
        model.profiles.seedPreview(SpotchatProfile(name: "Аня", bio: "Кофе, прогулки и хорошие разговоры"), for: wire.samples[0].peerID)
        model.didReceiveTransportEvent(.bluetoothStateUpdated(.poweredOn))
        model.didUpdatePeerSnapshots(wire.samples)
        let peer = wire.samples[0].peerID
        let lines: [(String, Bool)] = [
            ("Привет!", false), ("Привет", true),
            ("Ты тоже пробуешь Shum?", false),
            ("Да", true),
            ("Прикольно, что можно просто написать человеку рядом. Даже без интернета", true),
            ("Ага! Давай проверим", false),
            ("Раз, два…\nВсё долетело?", false),
            ("Всё работает!", true)
        ]
        model.messages = lines.enumerated().map { index, line in
            SpotchatMessage(id: "preview-\(index)", peerID: peer, text: line.0,
                date: Date().addingTimeInterval(Double(index - lines.count) * 30),
                outgoing: line.1, status: .read(by: "Аня", at: Date()))
        }
        for (index, text) in ["Увидимся!", "Привет, я тоже здесь", "Отличная идея 👍"].enumerated() {
            let sample = wire.samples[index + 1]
            let id = "preview-peer-\(index)"
            model.messages.append(SpotchatMessage(id: id, peerID: sample.peerID, text: text,
                date: Date().addingTimeInterval(-600), outgoing: false, status: .delivered(to: "Руслан", at: Date())))
            if index == 1 { model.unreadMessageIDs.insert("\(sample.peerID.id):\(id)") }
        }
        if ProcessInfo.processInfo.arguments.contains("-ShumPreviewEmptyChat") { model.messages = [] }
        if ProcessInfo.processInfo.arguments.contains("-ShumPreviewLongBio") {
            let bio = String(String(repeating: "Люблю прогулки, новые знакомства и разговоры о том, что вдохновляет. ", count: 3).prefix(SpotchatProfile.maxBioCharacters))
            model.profiles.seedPreview(SpotchatProfile(name: "Аня", bio: bio, avatar: SpotchatAvatarCodec.diagnosticPhoto(seed: 64)), for: peer)
        }
        return model
    }
    #endif

    #if DEBUG && targetEnvironment(simulator)
    private func seedPermanentPreview() throws {
        guard let permanent else { return }
        let names = ["Аня", "Максим", "Соня", "Дима"]
            + (ProcessInfo.processInfo.arguments.contains("-ShumPreviewLongList")
               ? (1...24).map { "Контакт \($0)" } : [])
        for name in names {
            let noise = Curve25519.KeyAgreement.PrivateKey()
            let signing = Curve25519.Signing.PrivateKey()
            var card = SpotchatContactCard(noiseKey: noise.publicKey.rawRepresentation, signingKey: signing.publicKey.rawRepresentation,
                nostrKey: try NostrIdentity.generate().publicKeyHex, name: name, bio: "Кофе, прогулки и хорошие разговоры")
            card.signature = try signing.signature(for: card.signedBytes())
            try permanent.add(card, source: "preview")
            try permanent.recordEncounter(card)
            if name == "Соня" { _ = try permanent.toggleSaved(card) }
            _ = permanent.send(name == "Максим" ? "Буду через десять минут" : "До встречи!", to: card)
        }
        let noise = Curve25519.KeyAgreement.PrivateKey()
        let signing = Curve25519.Signing.PrivateKey()
        var invitation = SpotchatContactCard(noiseKey: noise.publicKey.rawRepresentation, signingKey: signing.publicKey.rawRepresentation,
            nostrKey: try NostrIdentity.generate().publicKeyHex, name: "Александра", bio: "")
        invitation.signature = try signing.signature(for: invitation.signedBytes())
        try permanent.store.transaction { $0.requests.append(invitation) }
    }
    #endif

    init(transport: Transport, defaults: UserDefaults = .standard,
         profileStore: SpotchatProfileStore = SpotchatProfileStore(),
         now: @escaping () -> Date = Date.init) {
        self.transport = transport
        self.defaults = defaults
        self.now = now
        var initialName = defaults.string(forKey: "spotchat.nickname")
            .flatMap(InputValidator.validateNickname) ?? "Гость \(transport.myPeerID.id.prefix(4))"
        #if DEBUG
        if let testName = defaults.string(forKey: "ShumSelfTestName"),
           let run = defaults.string(forKey: "ShumSelfTestRun") {
            initialName = "SC-\(run) \(testName)"
        }
        #endif
        var activeStore = profileStore
        #if DEBUG
        if defaults.string(forKey: "ShumSelfTestRun") != nil { activeStore = SpotchatProfileStore() }
        #endif
        let profileModel = SpotchatProfiles(name: initialName, store: activeStore, now: now,
            connected: { transport.isPeerConnected($0) },
            send: { data, peer in (transport as? SpotchatProfileTransporting)?.sendSpotchatProfile(data, to: peer) })
        profiles = profileModel
        nickname = profileModel.own.name
        transport.eventDelegate = self
        transport.peerEventsDelegate = self
        transport.setNickname(nickname)
        profileChanges = profiles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        #if DEBUG && os(iOS)
        if let run = defaults.string(forKey: "ShumSelfTestRun") {
            let seed = nickname.utf8.reduce(0) { ($0 + Int($1)) % 255 }
            try? profiles.save(SpotchatProfile(name: nickname, bio: "Проверка профиля \(run)", avatar: SpotchatAvatarCodec.diagnosticPhoto(seed: seed)))
        }
        #endif
    }

    func retireForDeletion() {
        retired = true; setupFailed = true
        timer?.cancel(); timer = nil
        permanent?.retire()
        profiles.retire()
        transport.eventDelegate = nil; transport.peerEventsDelegate = nil
        if let ble = transport as? BLEService { ble.suspendForPanicReset() }
        else { transport.stopServices() }
        permanentChanges?.cancel(); profileChanges?.cancel()
        permanent = nil; messages = []; peers = []; knownPeers = [:]; nearbyDistances = [:]; unreadMessageIDs = []
    }

    func start(runTimer: Bool = true) {
        guard !started, !setupFailed, !retired else { return }
        started = true
        if bluetoothEnabled { transport.startServices() }
        permanent?.start()
        if runTimer {
            timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
                .sink { [weak self] _ in self?.tick() }
        }
        tick()
    }

    func setBluetoothEnabled(_ enabled: Bool) {
        guard !retired else { return }
        bluetoothEnabled = enabled
        if enabled && started && appActive { transport.startServices() }
        else if !enabled { transport.stopServices(); peers = []; nearbyDistances = [:] }
    }

    func setAppActive(_ active: Bool) {
        guard !retired, !setupFailed else { return }
        guard appActive != active else { return }
        appActive = active
        profiles.setAppActive(active)
        permanent?.setActive(active)
        // Suspension is not a delivery failure. On return give the BLE/Noise
        // session a fresh acknowledgement interval before retrying.
        for index in messages.indices {
            messages[index].lastProgress = now()
            if active { messages[index].lastAttempt = now() }
        }
        if active {
            if bluetoothEnabled { transport.startServices() }
            tick()
            markVisibleRead()
        }
        #if DEBUG
        recordSelfTestEvent(active ? "foreground" : "background")
        writeSelfTestResult()
        #endif
    }

    func saveNickname(_ name: String) -> Bool {
        guard let valid = InputValidator.validateNickname(name), valid.utf8.count <= 64 else {
            error = "Введите короткое имя без служебных символов."
            return false
        }
        return saveProfile(name: valid, bio: profiles.own.bio, avatar: profiles.own.avatar)
    }

    func saveProfile(name: String, bio: String, avatar: Data?) -> Bool {
        guard !retired else { return false }
        guard let valid = InputValidator.validateNickname(name), valid.utf8.count <= 64 else {
            error = "Введите короткое имя без служебных символов."; return false
        }
        let profile = SpotchatProfile(name: valid, bio: bio.trimmingCharacters(in: .whitespacesAndNewlines), avatar: avatar)
        guard profile.valid else { error = "Описание — до \(SpotchatProfile.maxBioCharacters) символов. Попробуйте выбрать фото ещё раз."; return false }
        do { try profiles.save(profile) }
        catch { self.error = "Не удалось сохранить профиль. Попробуйте ещё раз."; return false }
        do { try permanent?.updateProfile(name: valid, bio: profile.bio) }
        catch { self.error = error.localizedDescription; return false }
        nickname = valid
        defaults.set(valid, forKey: "spotchat.nickname")
        transport.setNickname(valid)
        return true
    }

    func displayName(_ peer: SpotchatPeer) -> String {
        permanent?.card(for: peer.id)?.name
            ?? permanent?.state.savedProfiles?.first(where: { $0.card.peerID == peer.id })?.card.name
            ?? permanent?.state.encounters?.first(where: { $0.card.peerID == peer.id })?.card.name
            ?? profiles.remote[peer.id]?.name
            ?? peers.first(where: { $0.id == peer.id })?.name
            ?? peer.name
    }

    var chatPeers: [SpotchatPeer] {
        guard let permanent else { return peers }
        let current: [SpotchatPeer] = permanent.state.conversations.sorted { a, b in
            let aTime = permanent.state.messages.last(where: { $0.envelope.conversationID == a.id })?.envelope.timestamp ?? Int64(a.createdAt.timeIntervalSince1970 * 1000)
            let bTime = permanent.state.messages.last(where: { $0.envelope.conversationID == b.id })?.envelope.timestamp ?? Int64(b.createdAt.timeIntervalSince1970 * 1000)
            return aTime > bTime
        }.compactMap { conversation in
            guard let contact = permanent.state.contacts.first(where: { $0.id == conversation.contactID }) else { return nil }
            return SpotchatPeer(id: contact.card.peerID, name: contact.card.name, lastConnected: contact.addedAt)
        }
        let legacy = (permanent.state.legacyHistory?.contacts ?? []).filter { old in
            !permanent.state.contacts.contains { $0.id == old.id }
        }.map { old in SpotchatPeer(id: ShumLegacyArchive.peerID(old.id), name: old.name, lastConnected: .distantPast) }
        return current + legacy
    }
    func profile(for peer: PeerID) -> SpotchatProfile? {
        if let permanent, let card = permanent.card(for: peer) {
            let avatar = permanent.session(for: card).flatMap { profiles.remote[$0]?.avatar }
                ?? permanent.state.contacts.first(where: { $0.id == card.id })?.avatar
                ?? permanent.state.savedProfiles?.first(where: { $0.id == card.id })?.avatar
                ?? permanent.state.encounters?.first(where: { $0.id == card.id })?.avatar
            return SpotchatProfile(name: card.name, bio: card.bio, avatar: avatar)
        }
        if let saved = permanent?.state.savedProfiles?.first(where: { $0.card.peerID == peer }) {
            return SpotchatProfile(name: saved.card.name, bio: saved.card.bio, avatar: saved.avatar)
        }
        if let encounter = permanent?.state.encounters?.first(where: { $0.card.peerID == peer }) {
            return SpotchatProfile(name: encounter.card.name, bio: encounter.card.bio, avatar: encounter.avatar)
        }
        return profiles.remote[peer]
    }
    func addContact(_ card: SpotchatContactCard, source: String) -> SpotchatPeer? {
        do {
            guard let permanent else { throw SpotchatFailure.unavailableIdentity }
            try permanent.add(card, source: source, avatar: permanent.session(for: card).flatMap { profiles.remote[$0]?.avatar })
            return SpotchatPeer(id: card.peerID, name: card.name, lastConnected: Date())
        } catch { self.error = error.localizedDescription; return nil }
    }
    private func syncPermanentMessages() {
        guard let permanent else { return }
        messages = permanent.state.messages.map { stored in
            let card = stored.outgoing ? stored.envelope.recipient : stored.envelope.sender
            let status: DeliveryStatus
            switch stored.status {
            case .queued: status = .sending
            case .forwarding: status = .sent
            case .delivered: status = .delivered(to: card.name, at: stored.deliveredAt ?? Date())
            case .read: status = .read(by: card.name, at: stored.readAt ?? Date())
            case .expired: status = .failed(reason: "Срок доставки истёк")
            case .cancelled: status = .failed(reason: "Отменено после блокировки")
            }
            return SpotchatMessage(id: stored.id, peerID: card.peerID, text: stored.text,
                date: Date(timeIntervalSince1970: Double(stored.envelope.timestamp) / 1000), outgoing: stored.outgoing,
                status: status, attempts: stored.attempts, deliveryLabel: stored.status == .forwarding && stored.deliveryTransport == "mesh" ? "Передаётся через mesh" : stored.status.label)
        }
        if let history = permanent.state.legacyHistory {
            messages += history.messages.map { old in
                let peer = permanent.state.contacts.first { $0.id == old.contactID }?.card.peerID ?? ShumLegacyArchive.peerID(old.contactID)
                return SpotchatMessage(id: "legacy-" + old.id, peerID: peer, text: old.text, date: old.date,
                    outgoing: old.outgoing, status: old.status, deliveryLabel: "История")
            }
            messages.sort { $0.date < $1.date }
        }
        unreadMessageIDs = Set(permanent.state.messages.filter { $0.unread }.map { "\($0.envelope.sender.peerID.id):\($0.id)" })
        objectWillChange.send()
    }

    func openConversation(_ peer: PeerID?) {
        activePeer = peer
        if let permanent { permanent.open(peer.flatMap { permanent.card(for: $0) }); return }
        if let peer, transport.isPeerConnected(peer) { transport.triggerHandshake(with: peer) }
        markVisibleRead()
    }

    func isLegacyOnly(_ peer: PeerID) -> Bool { peer.id.hasPrefix("legacy-") }

    func conversation(_ peer: PeerID) -> [SpotchatMessage] {
        messages.filter { $0.peerID == peer }
    }

    func unreadCount(for peer: PeerID) -> Int {
        conversation(peer).filter { !$0.outgoing && unreadMessageIDs.contains("\(peer.id):\($0.id)") }.count
    }

    func isBlocked(_ peer: PeerID) -> Bool {
        guard let permanent, let card = permanent.card(for: peer) else { return false }
        return permanent.isBlocked(card)
    }
    private func isBlockedSession(_ peer: PeerID) -> Bool {
        guard let key = transport.noiseSessionPublicKeyData(for: peer) else { return false }
        return permanent?.state.blocked?[SpotchatContactCard.userID(key)] != nil
    }
    func isNearby(_ peer: PeerID) -> Bool {
        guard bluetoothState == .poweredOn else { return false }
        if let permanent, let card = permanent.card(for: peer) { return permanent.session(for: card) != nil }
        return transport.isPeerConnected(peer)
    }

    func distanceMeters(for peer: PeerID) -> Int? {
        guard isNearby(peer) else { return nil }
        let session = permanent?.card(for: peer).flatMap { permanent?.session(for: $0) } ?? peer
        return nearbyDistances[session]
    }

    @discardableResult
    func send(_ text: String, to peer: PeerID) -> Bool {
        guard !setupFailed else { return false }
        if let permanent {
            guard let card = permanent.card(for: peer) else { error = "Дождитесь проверки профиля собеседника."; return false }
            return permanent.send(text, to: card)
        }
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }
        // Upstream private-message TLV has a one-byte length. Reject visibly
        // rather than silently dropping Cyrillic/emoji payloads above 255 bytes.
        guard content.utf8.count <= 255 else {
            error = "Для этой тестовой версии сократите сообщение или отправьте его частями."
            return false
        }
        guard isNearby(peer) else {
            error = "Собеседник сейчас недоступен. Подойдите ближе и попробуйте снова."
            return false
        }
        let message = SpotchatMessage(id: UUID().uuidString, peerID: peer,
                                      text: content, date: now(), outgoing: true, status: .sending)
        messages.append(message)
        trimMessages()
        transmit(id: message.id)
        return true
    }

    func retry(_ message: SpotchatMessage) {
        if let permanent, let card = permanent.card(for: message.peerID) {
            if case .failed = message.status { _ = permanent.send(message.text, to: card) }
            return
        }
        guard message.outgoing, isNearby(message.peerID),
              let index = messages.firstIndex(where: { $0.id == message.id && $0.outgoing }) else { return }
        guard case .failed = messages[index].status else { return }
        messages[index].attempts = 0
        messages[index].disconnectedWait = 0
        messages[index].status = .sending
        transmit(id: message.id)
    }

    private func transmit(id: String) {
        guard let index = messages.firstIndex(where: { $0.id == id && $0.outgoing }) else { return }
        messages[index].attempts += 1
        messages[index].lastAttempt = now()
        messages[index].lastProgress = now()
        messages[index].waitingForConnection = false
        let message = messages[index]
        transport.sendPrivateMessage(message.text, to: message.peerID,
                                     recipientNickname: knownPeers[message.peerID]?.name ?? "Гость",
                                     messageID: message.id)
    }

    func tick() {
        guard !retired else { return }
        internetConnected = permanent?.internetConnected == true
        didUpdatePeerSnapshots(transport.currentPeerSnapshots())
        if appActive {
            if transport is SpotchatProfileTransporting, bluetoothState == .poweredOn { profiles.tick() }
            if let permanent {
                permanent.tick(connected: Set(peers.filter { transport.isPeerConnected($0.id) }.map(\.id)), active: appActive)
                for peer in peers { if let profile = profiles.remote[peer.id] { permanent.updateAvatar(profile.avatar, for: peer.id) } }
            } else { advancePendingMessages() }
            markVisibleRead()
        }
        #if DEBUG
        runSelfTestIfRequested()
        #endif
    }

    private func advancePendingMessages() {
        // Only foreground time counts. A disconnect pauses transport attempts,
        // while a bounded wait prevents an endless "waiting for connection".
        for index in messages.indices where messages[index].outgoing {
            switch messages[index].status { case .sending, .sent: break; default: continue }
            let elapsed = max(0, now().timeIntervalSince(messages[index].lastProgress))
            messages[index].lastProgress = now()
            if !isNearby(messages[index].peerID) {
                messages[index].disconnectedWait += elapsed
                messages[index].waitingForConnection = true
                if messages[index].disconnectedWait >= Self.connectionWaitLimit {
                    messages[index].waitingForConnection = false
                    messages[index].status = .failed(reason: "Связь не восстановилась")
                }
                continue
            }
            if messages[index].waitingForConnection {
                messages[index].waitingForConnection = false
                if messages[index].attempts < Self.maxAttempts {
                    transmit(id: messages[index].id)
                } else {
                    // A flapping link must not replenish an exhausted retry budget.
                    messages[index].lastAttempt = now()
                }
            } else if now().timeIntervalSince(messages[index].lastAttempt) >= Self.retryInterval {
                if messages[index].attempts < Self.maxAttempts {
                    transmit(id: messages[index].id)
                } else {
                    messages[index].status = .failed(reason: "Нет подтверждения")
                }
            }
        }
    }

    func didUpdatePeerSnapshots(_ snapshots: [TransportPeerSnapshot]) {
        guard !retired else { return }
        let current = now()
        let connected = snapshots.filter { bluetoothState == .poweredOn && $0.peerID != transport.myPeerID && $0.isConnected && !isBlockedSession($0.peerID) }
        let ids = Set(connected.map(\.peerID))
        let distances = Dictionary(connected.compactMap { snapshot -> (PeerID, Int)? in
            guard let meters = snapshot.distanceMeters, meters > 0 else { return nil }
            return (snapshot.peerID, meters)
        }, uniquingKeysWith: { _, latest in latest })
        if nearbyDistances != distances { nearbyDistances = distances }
        #if DEBUG
        if defaults.string(forKey: "ShumSelfTestRun") != nil {
            for peer in ids.subtracting(testConnectedPeers) { recordSelfTestEvent("peer-connected", messageID: peer.id) }
            for peer in testConnectedPeers.subtracting(ids) { recordSelfTestEvent("peer-disconnected", messageID: peer.id) }
            testConnectedPeers = ids
        }
        #endif
        profiles.updatePeers(ids)
        for peer in connected.prefix(100) {
            knownPeers[peer.peerID] = SpotchatPeer(id: peer.peerID, name: peer.nickname, lastConnected: current)
        }
        knownPeers = knownPeers.filter { ids.contains($0.key) || current.timeIntervalSince($0.value.lastConnected) < Self.disappearanceDelay }
        peers = knownPeers.values.sorted { $0.name == $1.name ? $0.id.id < $1.id.id : $0.name < $1.name }
    }

    func didReceiveTransportEvent(_ event: TransportEvent) {
        guard !retired else { return }
        switch event {
        case .bluetoothStateUpdated(let state):
            bluetoothState = state
            if state != .poweredOn { knownPeers.removeAll(); peers = []; nearbyDistances = [:]; profiles.updatePeers([]) }
        case .peerSnapshotsUpdated(let snapshots): didUpdatePeerSnapshots(snapshots)
        case .peerConnected, .peerDisconnected, .peerListUpdated:
            internetConnected = permanent?.internetConnected == true
        didUpdatePeerSnapshots(transport.currentPeerSnapshots())
        case .noisePayloadReceived(let peer, let type, let data, let date):
            guard !isBlockedSession(peer) else { return }
            if type == .spotchatEnvelope { permanent?.receiveBytes(data, from: peer); return }
            if permanent != nil && type != .spotchatProfile { return }
            switch type {
            case .spotchatProfile:
                profiles.receive(data, from: peer)
            case .privateMessage:
                guard let packet = PrivateMessagePacket.decode(from: data),
                      !packet.messageID.isEmpty, packet.messageID.utf8.count <= 255,
                      !packet.content.isEmpty else { return }
                let dedupID = "\(peer.id):\(packet.messageID)"
                if receivedIDs.insert(dedupID).inserted {
                    if !appActive || activePeer != peer { unreadMessageIDs.insert(dedupID) }
                    receivedOrder.append(dedupID)
                    if receivedOrder.count > 4000 { receivedIDs.remove(receivedOrder.removeFirst()) }
                    messages.append(SpotchatMessage(id: packet.messageID, peerID: peer,
                                                   text: packet.content, date: date,
                                                   outgoing: false, status: .delivered(to: nickname, at: now())))
                    trimMessages()
                }
                #if DEBUG
                recordSelfTestEvent("received", messageID: packet.messageID)
                #endif
                transport.sendDeliveryAck(for: packet.messageID, to: peer)
                if appActive && activePeer == peer { sendRead(packet.messageID, to: peer) }
            case .delivered, .readReceipt:
                guard let id = String(data: data, encoding: .utf8),
                      let index = messages.firstIndex(where: { $0.id == id && $0.outgoing && $0.peerID == peer }) else { return }
                if case .read = messages[index].status { return }
                let name = knownPeers[peer]?.name ?? "Собеседник"
                messages[index].waitingForConnection = false
                messages[index].status = type == .readReceipt
                    ? .read(by: name, at: now()) : .delivered(to: name, at: now())
            default: break
            }
        case .messageDeliveryStatusUpdated(let id, let status):
            guard permanent == nil else { return }
            guard let index = messages.firstIndex(where: { $0.id == id && $0.outgoing }) else { return }
            // A local write or a late retry callback cannot override a receipt
            // or turn a timed-out message back into an endless spinner.
            switch messages[index].status {
            case .sending, .sent:
                switch status {
                case .sent: messages[index].status = .sent
                case .failed:
                    if !isNearby(messages[index].peerID) {
                        messages[index].waitingForConnection = true
                        messages[index].lastProgress = now()
                    } else { messages[index].status = status }
                default: break
                }
            default: break
            }
        default: break
        }
        #if DEBUG
        writeSelfTestResult()
        #endif
    }

    @discardableResult
    private func sendRead(_ id: String, to peer: PeerID) -> Bool {
        guard appActive, activePeer == peer, isNearby(peer) else { return false }
        let key = "\(peer.id):\(id)"
        let progress = readAttempts[key] ?? (count: 0, sentAt: Date.distantPast)
        guard progress.count < 3, now().timeIntervalSince(progress.sentAt) >= Self.retryInterval else { return false }
        readAttempts[key] = (progress.count + 1, now())
        transport.sendReadReceipt(ReadReceipt(originalMessageID: id,
            readerID: transport.myPeerID, readerNickname: nickname), to: peer)
        #if DEBUG
        recordSelfTestEvent("read-sent", messageID: id)
        #endif
        return true
    }

    private func markVisibleRead() {
        guard permanent == nil else { return }
        guard appActive, let peer = activePeer else { return }
        var sent = 0
        for message in conversation(peer) where !message.outgoing {
            unreadMessageIDs.remove("\(peer.id):\(message.id)")
            if sent < 20, sendRead(message.id, to: peer) { sent += 1 }
        }
    }

    private func trimMessages() {
        if messages.count > 1000 {
            for message in messages.prefix(messages.count - 1000) {
                unreadMessageIDs.remove("\(message.peerID.id):\(message.id)")
                readAttempts["\(message.peerID.id):\(message.id)"] = nil
            }
            messages.removeFirst(messages.count - 1000)
        }
    }

    #if DEBUG
    // Explicit opt-in only, for the two owner-controlled test phones. Synthetic
    // messages target only another device advertising the same random test run.
    private var testedPeers: Set<PeerID> = []
    private let testSession = UUID().uuidString
    private var testConnectedPeers: Set<PeerID> = []
    private var testEvents: [[String: Any]] = []
    private var testCommands: Set<String> = []
    private var testRadioResumeAt: Date?
    private func recordSelfTestEvent(_ event: String, messageID: String? = nil) {
        guard defaults.string(forKey: "ShumSelfTestRun") != nil else { return }
        var row: [String: Any] = ["event": event, "active": appActive, "at": ISO8601DateFormatter().string(from: now())]
        if let messageID { row["id"] = messageID }
        testEvents.append(row)
        if testEvents.count > 200 { testEvents.removeFirst(testEvents.count - 200) }
    }
    private func processSelfTestCommand(run: String) {
        guard ProcessInfo.processInfo.arguments.contains("-ShumSelfTestStage5"), appActive,
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: directory.appendingPathComponent("spotchat-test-command.json")), data.count < 2048,
              let command = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              command["run"] == run, let id = command["id"], id.utf8.count <= 40, !testCommands.contains(id) else { return }
        switch command["action"] {
        case "send":
            guard let peer = peers.first(where: { $0.name.hasPrefix("SC-\(run) ") && isNearby($0.id) }),
                  send("Shum BLE test \(run) phase:\(id)", to: peer.id) else { return }
            testCommands.insert(id)
            recordSelfTestEvent("command-send", messageID: id)
        case "pause-radio":
            testCommands.insert(id)
            testRadioResumeAt = now().addingTimeInterval(20)
            transport.stopServices()
            recordSelfTestEvent("radio-stop")
        default: break
        }
    }
    private func runSelfTestIfRequested() {
        guard let run = defaults.string(forKey: "ShumSelfTestRun"), !run.isEmpty else { return }
        if let resumeAt = testRadioResumeAt {
            if now() < resumeAt { writeSelfTestResult(); return }
            testRadioResumeAt = nil
            if bluetoothEnabled { transport.startServices() }
            recordSelfTestEvent("radio-start")
        }
        processSelfTestCommand(run: run)
        for peer in peers where peer.name.hasPrefix("SC-\(run) ") && !testedPeers.contains(peer.id) {
            if send("Shum BLE test \(run) от \(nickname)", to: peer.id) { testedPeers.insert(peer.id) }
        }
        writeSelfTestResult()
    }

    private func writeSelfTestResult() {
        guard let run = defaults.string(forKey: "ShumSelfTestRun"), !run.isEmpty else { return }
        let synthetic = messages.filter { $0.text.hasPrefix("Shum BLE test \(run) ") }
        let confirmed = synthetic.filter {
            guard $0.outgoing else { return false }
            switch $0.status { case .delivered, .read: return true; default: return false }
        }
        let receivedProfiles = profiles.remote.values.filter { $0.name.hasPrefix("SC-\(run) ") && $0.bio == "Проверка профиля \(run)" }
        let receivedPhotos = receivedProfiles.compactMap(\.avatar)
        let result: [String: Any] = [
            "run": run, "name": nickname, "transport": "BLEService",
            "session": testSession, "appActive": appActive,
            "activePeer": activePeer?.id ?? "",
            "events": testEvents,
            "messages": synthetic.map { message -> [String: Any] in
                let state: String
                switch message.status {
                case .read: state = "read"
                case .delivered: state = "delivered"
                case .failed: state = "failed"
                default: state = message.waitingForConnection ? "waiting" : "sending"
                }
                return ["id": message.id, "text": message.text, "outgoing": message.outgoing,
                        "status": state, "attempts": message.attempts,
                        "unread": unreadMessageIDs.contains("\(message.peerID.id):\(message.id)")]
            },
            "bluetoothPoweredOn": bluetoothState == .poweredOn,
            "nearbyCount": peers.count,
            "profileReceivedCount": receivedProfiles.count,
            "avatarReceivedCount": receivedPhotos.count,
            "ownAvatarHash": profiles.own.avatar.map(SpotchatProfile.digest) ?? "",
            "receivedAvatarHashes": receivedPhotos.map(SpotchatProfile.digest),
            "receivedAvatarBytes": receivedPhotos.map(\.count),
            "sentCount": synthetic.filter(\.outgoing).count,
            "receivedCount": synthetic.filter { !$0.outgoing }.count,
            "confirmedCount": confirmed.count,
            "updatedAt": ISO8601DateFormatter().string(from: now())
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
              let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: directory.appendingPathComponent("spotchat-test-result.json"), options: .atomic)
    }
    #endif
}
