import Combine
import Foundation

struct ShumResolvedContact {
    let card: ShumContactCard
    let profile: ShumProfile
}

@MainActor
final class ShumNostrService {
    private struct ContactRequest: Codable {
        let id: String
    }

    private struct ContactManifest: Codable {
        let id: String
        let card: ShumContactCard
        let profile: ShumProfileManifest
    }

    private struct ContactChunk: Codable {
        let id: String
        let hash: String
        let offset: Int
        let data: Data
    }

    private enum Inbound {
        case packet(ShumPacket, String)
        case contactRequest(ContactRequest, String)
        case contactManifest(ContactManifest, String)
        case contactChunk(ContactChunk, String)
    }

    private struct Lookup {
        let target: String
        let completion: (Result<ShumResolvedContact, Error>) -> Void
        var card: ShumContactCard?
        var profile: ShumProfileManifest?
        var chunks: [Int: Data] = [:]
    }

    let manager: NostrRelayManager
    private let identity: NostrIdentity
    var received: ((ShumPacket, String) -> Void)?
    private var cardProvider: (() -> ShumContactCard?)?
    private var profileProvider: (() -> ShumProfile?)?
    private var seen: Set<String> = []
    private var queuedEvents: [NostrEvent] = []
    private var lookups: [String: Lookup] = [:]
    private var responseRate: [String: Date] = [:]
    private var pending = 0
    private var started = false
    nonisolated private static let requestPrefix = "shum-contact-request-v1:"
    nonisolated private static let manifestPrefix = "shum-contact-manifest-v1:"
    nonisolated private static let chunkPrefix = "shum-contact-chunk-v1:"
    private static let lookupTimeout: TimeInterval = 20

    init(identity: NostrIdentity, manager: NostrRelayManager) {
        self.identity = identity; self.manager = manager
    }
    var connected: Bool { manager.isDMRelayConnected }

    func configureContactLookup(
        card: @escaping () -> ShumContactCard?,
        profile: @escaping () -> ShumProfile?
    ) {
        cardProvider = card
        profileProvider = profile
    }

    func start() {
        guard !started else { return }; started = true
        manager.connect()
        // Outer timestamps are randomized by bitchat; allow that skew when fetching.
        manager.subscribe(filter: .giftWrapsFor(pubkey: identity.publicKeyHex, since: Date().addingTimeInterval(-3 * 86400)), id: "shum-private-v1") { [weak self] event in
            self?.receive(event)
        }
    }
    func stop() { started = false; manager.disconnect() }
    private func receive(_ event: NostrEvent) {
        guard !seen.contains(event.id) else { return }
        if seen.count >= 1000 { seen.removeAll(keepingCapacity: true) }
        seen.insert(event.id)
        if pending >= 4 {
            if queuedEvents.count < 128 { queuedEvents.append(event) }
            return
        }
        decode(event)
    }

    private func decode(_ event: NostrEvent) {
        pending += 1
        let identity = identity
        Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) { () -> Inbound? in
                guard let result = try? NostrProtocol.decryptPrivateMessage(giftWrap: event, recipientIdentity: identity),
                      result.senderPubkey.count == 64 else { return nil }
                let content = result.content
                for prefix in [
                    ShumWireProtocol.relayPrefix,
                    ShumWireProtocol.legacyRelayPrefix
                ] where content.hasPrefix(prefix) {
                    guard content.utf8.count <= 33_000,
                          let bytes = Data(
                            base64Encoded: String(content.dropFirst(prefix.count))
                          ), bytes.count <= 24_000,
                          let packet = try? JSONDecoder().decode(
                            ShumPacket.self,
                            from: bytes
                          ) else { return nil }
                    return .packet(packet, result.senderPubkey)
                }
                if content.hasPrefix(Self.requestPrefix),
                   let request = Self.decode(ContactRequest.self, content: content, prefix: Self.requestPrefix, limit: 256) {
                    return .contactRequest(request, result.senderPubkey)
                }
                if content.hasPrefix(Self.manifestPrefix),
                   let manifest = Self.decode(ContactManifest.self, content: content, prefix: Self.manifestPrefix, limit: 4_096) {
                    return .contactManifest(manifest, result.senderPubkey)
                }
                if content.hasPrefix(Self.chunkPrefix),
                   let chunk = Self.decode(ContactChunk.self, content: content, prefix: Self.chunkPrefix, limit: 6_144) {
                    return .contactChunk(chunk, result.senderPubkey)
                }
                return nil
            }.value
            guard let self else { return }; self.pending -= 1
            if let decoded { self.receive(decoded) }
            self.drainQueue()
        }
    }

    private func drainQueue() {
        while pending < 4, !queuedEvents.isEmpty {
            decode(queuedEvents.removeFirst())
        }
    }
    func send(_ packet: ShumPacket, to card: ShumContactCard, completion: @escaping (Bool) -> Void) {
        guard connected, let bytes = try? ShumCoding.encode(packet) else { completion(false); return }
        NostrTransport.sendShum(bytes, recipient: card.nostrKey, identity: identity, manager: manager, completion: completion)
    }

    func resolve(_ locator: ShumContactLocator, completion: @escaping (Result<ShumResolvedContact, Error>) -> Void) {
        guard locator.nostrKey != identity.publicKeyHex, lookups.count < 8 else {
            completion(.failure(ShumFailure.invalidContact))
            return
        }
        start()
        let id = UUID().uuidString.lowercased()
        lookups[id] = Lookup(target: locator.nostrKey, completion: completion)
        guard send(ContactRequest(id: id), prefix: Self.requestPrefix, recipient: locator.nostrKey) else {
            lookups.removeValue(forKey: id)
            completion(.failure(ShumFailure.contactUnavailable))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lookupTimeout) { [weak self] in
            guard let lookup = self?.lookups.removeValue(forKey: id) else { return }
            lookup.completion(.failure(ShumFailure.contactUnavailable))
        }
    }

    private func receive(_ inbound: Inbound) {
        switch inbound {
        case .packet(let packet, let sender):
            received?(packet, sender)
        case .contactRequest(let request, let sender):
            respond(to: request, sender: sender)
        case .contactManifest(let manifest, let sender):
            accept(manifest, sender: sender)
        case .contactChunk(let chunk, let sender):
            accept(chunk, sender: sender)
        }
    }

    private func respond(to request: ContactRequest, sender: String) {
        if responseRate.count >= 1_000 {
            responseRate = responseRate.filter { Date().timeIntervalSince($0.value) < 300 }
        }
        guard Self.validRequestID(request.id), sender != identity.publicKeyHex,
              responseRate.count < 1_000 || responseRate[sender] != nil,
              Date().timeIntervalSince(responseRate[sender] ?? .distantPast) >= 3,
              let card = cardProvider?(), let ownProfile = profileProvider?(),
              card.nostrKey == identity.publicKeyHex, (try? card.validate()) != nil else { return }
        responseRate[sender] = Date()

        let avatar = ownProfile.avatar.flatMap { ShumProfile.validAvatar($0) ? $0 : nil }
        let profile = ShumProfile(name: card.name, bio: card.bio, avatar: avatar)
        let manifest = ContactManifest(id: request.id, card: card, profile: ShumProfileManifest(profile))
        guard send(manifest, prefix: Self.manifestPrefix, recipient: sender), let avatar else { return }

        let hash = ShumProfile.digest(avatar)
        for offset in stride(from: 0, to: avatar.count, by: ShumProfilePacket.chunkSize) {
            let end = min(avatar.count, offset + ShumProfilePacket.chunkSize)
            let chunk = ContactChunk(id: request.id, hash: hash, offset: offset, data: avatar.subdata(in: offset ..< end))
            _ = send(chunk, prefix: Self.chunkPrefix, recipient: sender)
        }
    }

    private func accept(_ response: ContactManifest, sender: String) {
        guard Self.validRequestID(response.id), var lookup = lookups[response.id],
              lookup.target == sender, response.card.nostrKey == sender,
              response.profile.valid, response.profile.name == response.card.name,
              response.profile.bio == response.card.bio,
              (try? response.card.validate()) != nil else { return }
        lookup.card = response.card
        lookup.profile = response.profile
        lookups[response.id] = lookup
        finishIfComplete(response.id)
    }

    private func accept(_ chunk: ContactChunk, sender: String) {
        guard Self.validRequestID(chunk.id), var lookup = lookups[chunk.id],
              lookup.target == sender, ShumProfileManifest.validHash(chunk.hash),
              chunk.offset >= 0, chunk.offset < ShumProfile.maxAvatarBytes,
              chunk.offset % ShumProfilePacket.chunkSize == 0,
              !chunk.data.isEmpty, chunk.data.count <= ShumProfilePacket.chunkSize,
              chunk.offset + chunk.data.count <= ShumProfile.maxAvatarBytes else { return }
        lookup.chunks[chunk.offset] = chunk.data
        lookups[chunk.id] = lookup
        finishIfComplete(chunk.id)
    }

    private func finishIfComplete(_ id: String) {
        guard let lookup = lookups[id], let card = lookup.card, let manifest = lookup.profile else { return }
        if manifest.avatarBytes == 0 {
            lookups.removeValue(forKey: id)
            lookup.completion(.success(ShumResolvedContact(
                card: card,
                profile: ShumProfile(name: manifest.name, bio: manifest.bio)
            )))
            return
        }
        guard let expectedHash = manifest.avatarHash else { return }
        var avatar = Data()
        while avatar.count < manifest.avatarBytes {
            guard let chunk = lookup.chunks[avatar.count] else { return }
            avatar.append(chunk)
        }
        guard avatar.count == manifest.avatarBytes,
              ShumProfile.digest(avatar) == expectedHash,
              ShumProfile.validAvatar(avatar) else { return }
        lookups.removeValue(forKey: id)
        lookup.completion(.success(ShumResolvedContact(
            card: card,
            profile: ShumProfile(name: manifest.name, bio: manifest.bio, avatar: avatar)
        )))
    }

    private func send<T: Encodable>(_ value: T, prefix: String, recipient: String) -> Bool {
        guard recipient.count == 64,
              let data = try? JSONEncoder().encode(value), data.count <= 6_144 else { return false }
        let content = prefix + data.base64EncodedString()
        guard let event = try? NostrProtocol.createPrivateMessage(
            content: content,
            recipientPubkey: recipient,
            senderIdentity: identity
        ) else { return false }
        manager.sendEvent(event)
        return true
    }

    nonisolated private static func decode<T: Decodable>(
        _ type: T.Type,
        content: String,
        prefix: String,
        limit: Int
    ) -> T? {
        let encoded = String(content.dropFirst(prefix.count))
        guard encoded.utf8.count <= ((limit + 2) / 3) * 4 + 4,
              let data = Data(base64Encoded: encoded), data.count <= limit else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func validRequestID(_ id: String) -> Bool {
        id.utf8.count == 36 && UUID(uuidString: id) != nil
    }
}
