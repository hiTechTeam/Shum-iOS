import BitFoundation
import CryptoKit
import Foundation

/// The first build stored no signed Nostr contact cards. Preserve those messages
/// as local history, then join by the authenticated Noise-key fingerprint when
/// the same contact is encountered again. Never fabricate a signed contact.
struct ShumLegacyArchive: Codable {
    var contacts: [ShumLegacyContact]
    var messages: [ShumLegacyMessage]
    static func peerID(_ contactID: String) -> PeerID { PeerID(str: "legacy-" + contactID) }
}

@MainActor
enum ShumHistoryMigration {
    static func migrate(into store: ShumConversationStore, url: URL,
                        readKey: () throws -> Data?) throws {
        guard store.state.legacyHistory == nil else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let key = try readKey(), key.count == 32 else { throw ShumFailure.unavailableIdentity }
        let data = try Data(contentsOf: url)
        guard data.count <= 100_000_000 else { throw ShumFailure.storage }
        let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key))
        let archive = try JSONDecoder().decode(ShumLegacyArchive.self, from: bytes)
        try store.transaction { $0.legacyHistory = archive }
        // Keep the original encrypted file as a recovery copy until profile deletion.
    }
    static func live(into store: ShumConversationStore) throws {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shum-chats-v1.enc")
        try migrate(into: store, url: url) { try KeychainStore.shared.data(for: "shum.chat.storage-key") }
    }
}
