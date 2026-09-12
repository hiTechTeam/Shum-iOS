import Combine
import Foundation

@MainActor
final class SpotchatNostrService {
    let manager: NostrRelayManager
    private let identity: NostrIdentity
    var received: ((SpotchatPacket, String) -> Void)?
    private var seen: Set<String> = []
    private var pending = 0
    private var started = false
    init(identity: NostrIdentity, manager: NostrRelayManager) {
        self.identity = identity; self.manager = manager
    }
    var connected: Bool { manager.isDMRelayConnected }
    func start() {
        guard !started else { return }; started = true
        manager.connect()
        // Outer timestamps are randomized by bitchat; allow that skew when fetching.
        manager.subscribe(filter: .giftWrapsFor(pubkey: identity.publicKeyHex, since: Date().addingTimeInterval(-3 * 86400)), id: "spotchat-private-v1") { [weak self] event in
            self?.receive(event)
        }
    }
    func stop() { started = false; manager.disconnect() }
    private func receive(_ event: NostrEvent) {
        guard pending < 4, !seen.contains(event.id) else { return }
        if seen.count >= 1000 { seen.removeAll(keepingCapacity: true) }
        seen.insert(event.id); pending += 1
        let identity = identity
        Task { [weak self] in
            let decoded = await Task.detached(priority: .utility) { () -> (SpotchatPacket, String)? in
                guard let result = try? NostrProtocol.decryptPrivateMessage(giftWrap: event, recipientIdentity: identity),
                      result.content.hasPrefix("spotchat-v1:"), result.content.utf8.count <= 33_000,
                      let bytes = Data(base64Encoded: String(result.content.dropFirst(12))), bytes.count <= 24_000,
                      let packet = try? JSONDecoder().decode(SpotchatPacket.self, from: bytes) else { return nil }
                return (packet, result.senderPubkey)
            }.value
            guard let self else { return }; self.pending -= 1
            if let decoded { self.received?(decoded.0, decoded.1) }
        }
    }
    func send(_ packet: SpotchatPacket, to card: SpotchatContactCard, completion: @escaping (Bool) -> Void) {
        guard connected, let bytes = try? SpotchatCoding.encode(packet) else { completion(false); return }
        NostrTransport.sendSpotchat(bytes, recipient: card.nostrKey, identity: identity, manager: manager, completion: completion)
    }
}
