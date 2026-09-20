import BitFoundation
import CryptoKit
import Foundation

enum ShumWireProtocol {
    static let messageName = "shum.message.v1"
    static let legacyMessageName = "spotchat.message.v1"
    static let relayPrefix = "shum-v1:"
    static let legacyRelayPrefix = "spotchat-v1:"
}

struct ShumContact: Codable, Identifiable {
    var card: ShumContactCard
    var addedAt: Date
    var avatar: Data?
    var metadata: [String: String] = [:]
    var id: String { card.id }
}
struct ShumEncounter: Codable, Equatable, Identifiable {
    var card: ShumContactCard
    var firstSeen: Date
    var lastSeen: Date
    var seenCount: Int
    var avatar: Data?
    var id: String { card.id }
}
struct ShumSavedProfile: Codable, Equatable, Identifiable {
    var card: ShumContactCard
    var savedAt: Date
    var avatar: Data?
    var id: String { card.id }
}
struct ShumConversation: Codable, Identifiable {
    var id: String
    var contactID: String
    var createdAt: Date
    static func identifier(_ first: String, _ second: String) -> String {
        ShumContactCard.userID(Data([first, second].sorted().joined(separator: ":").utf8))
    }
}
enum ShumInvitationPhase: String, Codable {
    case ready
    case outgoingPending
    case incomingPending
    case accepted
    case declinedByPeer
    case declinedLocally
}
struct ShumInvitationState: Codable, Equatable {
    var phase: ShumInvitationPhase
    var updatedAt: Int64
    var eventID: String
}
enum ShumInvitationAction: String, Codable {
    case request
    case accept
    case decline
}
struct ShumInvitationControl: Codable, Equatable, Identifiable {
    var version = 1
    var id: String
    var sender: ShumContactCard
    var recipient: ShumContactCard
    var action: ShumInvitationAction
    var timestamp: Int64
    var expiresAt: Int64
    var signature = Data()

    func signingBytes() throws -> Data {
        var value = self
        value.signature = Data()
        return try ShumCoding.encode(value)
    }

    func validate(at now: Date) throws {
        try sender.validate()
        try recipient.validate()
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        guard version == 1,
              UUID(uuidString: id) != nil,
              sender.id != recipient.id,
              timestamp >= 0,
              timestamp <= milliseconds + 300_000,
              expiresAt > milliseconds,
              expiresAt > timestamp,
              expiresAt - timestamp <= 30 * 86_400_000,
              try Curve25519.Signing.PublicKey(rawRepresentation: sender.signingKey)
                .isValidSignature(signature, for: signingBytes()) else {
            throw ShumFailure.invalidMessage
        }
    }
}
struct ShumStoredInvitationControl: Codable, Equatable, Identifiable {
    var control: ShumInvitationControl
    var lastAttempt: Date = .distantPast
    var attempts = 0
    var nostrAccepted = false
    var id: String { control.id }
}
struct ShumTypingControl: Codable, Equatable, Identifiable {
    var version = 1
    var id: String
    var sender: ShumContactCard
    var recipient: ShumContactCard
    var isTyping: Bool
    var timestamp: Int64
    var expiresAt: Int64
    var signature = Data()

    func signingBytes() throws -> Data {
        var value = self
        value.signature = Data()
        return try ShumCoding.encode(value)
    }

    func validate(at now: Date) throws {
        try sender.validate()
        try recipient.validate()
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        guard version == 1,
              UUID(uuidString: id) != nil,
              sender.id != recipient.id,
              timestamp >= 0,
              timestamp <= milliseconds + 30_000,
              expiresAt > milliseconds,
              expiresAt > timestamp,
              expiresAt - timestamp <= 10_000,
              try Curve25519.Signing.PublicKey(rawRepresentation: sender.signingKey)
                .isValidSignature(signature, for: signingBytes()) else {
            throw ShumFailure.invalidMessage
        }
    }
}
struct ShumPresenceControl: Codable, Equatable, Identifiable {
    var version = 1
    var id: String
    var sender: ShumContactCard
    var recipient: ShumContactCard
    var isOnline: Bool
    var timestamp: Int64
    var expiresAt: Int64
    var signature = Data()

    func signingBytes() throws -> Data {
        var value = self
        value.signature = Data()
        return try ShumCoding.encode(value)
    }

    func validate(at now: Date) throws {
        try sender.validate()
        try recipient.validate()
        let milliseconds = Int64(now.timeIntervalSince1970 * 1000)
        guard version == 1,
              UUID(uuidString: id) != nil,
              sender.id != recipient.id,
              timestamp >= 0,
              timestamp <= milliseconds + 30_000,
              expiresAt > milliseconds,
              expiresAt > timestamp,
              expiresAt - timestamp <= 90_000,
              try Curve25519.Signing.PublicKey(rawRepresentation: sender.signingKey)
                .isValidSignature(signature, for: signingBytes()) else {
            throw ShumFailure.invalidMessage
        }
    }
}
enum ShumDelivery: String, Codable {
    case queued, forwarding, delivered, read, expired, cancelled
    var label: String {
        switch self {
        case .queued: return "В очереди"
        case .forwarding: return "Передаётся"
        case .delivered: return "Доставлено"
        case .read: return "Прочитано"
        case .expired: return "Срок доставки истёк"
        case .cancelled: return "Отменено"
        }
    }
}
struct ShumEnvelope: Codable, Equatable, Identifiable {
    var version = 1
    var id: String
    var conversationID: String
    var sender: ShumContactCard
    var recipient: ShumContactCard
    var timestamp: Int64
    var expiresAt: Int64
    var hopLimit = 4
    var ciphertext: Data
    var signature = Data()
    var digest: String { ShumContactCard.userID(ciphertext) }
    func signingBytes() throws -> Data {
        var value = self; value.signature = Data(); return try ShumCoding.encode(value)
    }
    func validate(at now: Date) throws {
        try sender.validate(); try recipient.validate()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        guard version == 1, UUID(uuidString: id) != nil, sender.id != recipient.id,
              conversationID == ShumConversation.identifier(sender.id, recipient.id),
              timestamp >= 0, timestamp <= ms + 300_000,
              expiresAt > ms, expiresAt > timestamp, expiresAt - timestamp <= 86_400_000,
              (1...4).contains(hopLimit), !ciphertext.isEmpty, ciphertext.count <= 12_000,
              try Curve25519.Signing.PublicKey(rawRepresentation: sender.signingKey).isValidSignature(signature, for: signingBytes()) else { throw ShumFailure.invalidMessage }
    }
}
struct ShumPlaintext: Codable {
    var protocolName = ShumWireProtocol.messageName
    var id: String
    var conversationID: String
    var senderID: String
    var recipientID: String
    var timestamp: Int64
    var expiresAt: Int64
    var text: String
    var reply: ShumReplyReference? = nil
}

struct ShumReplyReference: Codable, Hashable {
    var messageID: String
    var senderID: String
    var text: String
}

struct ShumStoredMessage: Codable, Identifiable {
    var envelope: ShumEnvelope
    var text: String // Entire snapshot is encrypted at rest; relays never receive this field.
    var outgoing: Bool
    var status: ShumDelivery
    var unread = false
    var hopCount = 0
    var deliveryTransport: String?
    var attempts = 0
    var lastAttempt: Date = .distantPast
    var forwardedTo: Set<String> = []
    var nostrAccepted = false
    var deliveredAt: Date?
    var readAt: Date?
    var reply: ShumReplyReference? = nil
    var id: String { envelope.id }
}
struct ShumRelayCopy: Codable {
    var envelope: ShumEnvelope
    var hopCount: Int
    var depositor: String
    var forwardedTo: Set<String> = []
    var lastDirectAttempt: Date = .distantPast
}
struct ShumReceipt: Codable, Equatable {
    var envelopeID: String
    var digest: String
    var sender: ShumContactCard // Recipient of the original message, signing this ACK.
    var destination: ShumContactCard
    var read: Bool
    var timestamp: Int64
    var expiresAt: Int64
    var signature = Data()
    var key: String { envelopeID + ":" + digest + ":" + sender.id }
    func signingBytes() throws -> Data {
        var value = self; value.signature = Data(); return try ShumCoding.encode(value)
    }
    func validate(at now: Date) throws {
        try sender.validate(); try destination.validate()
        let ms = Int64(now.timeIntervalSince1970 * 1000)
        guard UUID(uuidString: envelopeID) != nil, digest.count == 64,
              timestamp >= 0, timestamp <= ms + 300_000, expiresAt > ms,
              expiresAt <= ms + 86_700_000,
              try Curve25519.Signing.PublicKey(rawRepresentation: sender.signingKey).isValidSignature(signature, for: signingBytes()) else { throw ShumFailure.invalidMessage }
    }
}
struct ShumStoredReceipt: Codable {
    var receipt: ShumReceipt
    var lastAttempt: Date = .distantPast
    var sentTo: Set<String> = []
    var nostrAccepted = false
}
struct ShumPacket: Codable {
    var version = 1
    var card: ShumContactCard?
    var envelope: ShumEnvelope?
    var hopCount: Int?
    var receipt: ShumReceipt?
    var invitation: ShumInvitationControl?
    var typing: ShumTypingControl?
    var presence: ShumPresenceControl?
}
struct ShumDatabase: Codable {
    var version = 1
    var ownerID: String
    var contacts: [ShumContact] = []
    var requests: [ShumContactCard] = []
    var conversations: [ShumConversation] = []
    var messages: [ShumStoredMessage] = []
    var relay: [ShumRelayCopy] = []
    var receipts: [ShumStoredReceipt] = []
    var seenRelay: [String: Date] = [:]
    // Optional additions decode older v1 snapshots without discarding history.
    var blocked: [String: ShumContactCard]?
    var deletedMessageIDs: [String: Date]?
    var legacyHistory: ShumLegacyArchive?
    var encounters: [ShumEncounter]?
    var savedProfiles: [ShumSavedProfile]?
    var unviewedEncounterIDs: Set<String>?
    // Ordered like Telegram's pinned indices: the first identifier is shown first.
    var pinnedDirectoryEntries: [String: [String]]?
    var invitationStates: [String: ShumInvitationState]?
    var invitationOutbox: [ShumStoredInvitationControl]?
}

@MainActor
final class ShumConversationStore {
    private(set) var state: ShumDatabase
    private let url: URL?
    private let key: SymmetricKey
    init(ownerID: String, key: SymmetricKey, url: URL?) throws {
        self.key = key; self.url = url
        if let url, FileManager.default.fileExists(atPath: url.path) {
            let encrypted = try Data(contentsOf: url)
            guard encrypted.count <= 100_000_000 else { throw ShumFailure.storage }
            let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: encrypted), using: key)
            var restored = try JSONDecoder().decode(ShumDatabase.self, from: plain)
            guard restored.version == 1, restored.ownerID == ownerID else { throw ShumFailure.unavailableIdentity }
            // Builds before chat invitations allowed every saved contact to
            // message immediately. Preserve that access during migration.
            if restored.invitationStates == nil {
                restored.invitationStates = Dictionary(uniqueKeysWithValues: restored.contacts.map { contact in
                    let timestamp = Int64(contact.addedAt.timeIntervalSince1970 * 1000)
                    return (contact.id, ShumInvitationState(
                        phase: .accepted,
                        updatedAt: timestamp,
                        eventID: "legacy-\(contact.id)"
                    ))
                })
            }
            if restored.invitationOutbox == nil { restored.invitationOutbox = [] }
            // Saved profiles were replaced by per-folder pinning. Keep the
            // optional field only so older encrypted snapshots still decode.
            restored.savedProfiles = nil
            state = restored
        } else {
            state = ShumDatabase(
                ownerID: ownerID,
                invitationStates: [:],
                invitationOutbox: []
            )
        }
    }
    // Commit disk first, publish memory second: a failed save never ACKs or loses durable history.
    func transaction(_ update: (inout ShumDatabase) throws -> Void) throws {
        var next = state; try update(&next)
        if let url {
            let bytes = try ChaChaPoly.seal(ShumCoding.encode(next), using: key).combined
            guard bytes.count <= 100_000_000 else { throw ShumFailure.quota }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #if os(iOS)
            try bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try bytes.write(to: url, options: .atomic)
            #endif
            var directory = url.deletingLastPathComponent()
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }
        state = next
    }
    static var liveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShumConversations/state.enc")
    }
}

@MainActor
final class ShumContactsService {
    let store: ShumConversationStore
    init(store: ShumConversationStore) { self.store = store }
    func add(_ card: ShumContactCard, source: String, avatar: Data? = nil, now: Date = Date()) throws {
        try card.validate()
        guard card.id != store.state.ownerID else { throw ShumFailure.invalidContact }
        if let existing = store.state.contacts.first(where: { $0.id == card.id }), existing.card == card,
           avatar == nil || existing.avatar == avatar { return }
        try store.transaction { state in
            if let index = state.contacts.firstIndex(where: { $0.id == card.id }) {
                // Identity bindings are pinned. Name/bio updates cannot rotate authentication keys.
                guard state.contacts[index].card.signingKey == card.signingKey,
                      state.contacts[index].card.nostrKey == card.nostrKey else { throw ShumFailure.invalidContact }
                state.contacts[index].card = card
                if let avatar, avatar.count <= 40_960 { state.contacts[index].avatar = avatar }
            } else {
                guard state.contacts.count < 2000 else { throw ShumFailure.quota }
                state.contacts.append(ShumContact(card: card, addedAt: now, avatar: avatar, metadata: ["source": source]))
            }
        }
    }
    func conversation(with card: ShumContactCard, now: Date) throws {
        let id = ShumConversation.identifier(store.state.ownerID, card.id)
        guard !store.state.conversations.contains(where: { $0.id == id }) else { return }
        try store.transaction { $0.conversations.append(ShumConversation(id: id, contactID: card.id, createdAt: now)) }
    }
}
