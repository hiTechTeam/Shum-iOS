import Foundation

enum NostrTransport {}
extension NostrTransport {
    @MainActor
    static func sendSpotchat(_ data: Data, recipient: String, identity: NostrIdentity,
                             manager: NostrRelayManager, completion: @escaping (Bool) -> Void) {
        guard data.count <= 24_000,
              let event = try? NostrProtocol.createPrivateMessage(
                content: "spotchat-v1:" + data.base64EncodedString(),
                recipientPubkey: recipient, senderIdentity: identity) else { completion(false); return }
        manager.sendEventImmediately(event, completion: completion)
    }
}
