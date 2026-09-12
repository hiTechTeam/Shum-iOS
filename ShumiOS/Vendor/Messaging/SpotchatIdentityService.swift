import BitFoundation
import CryptoKit
import Foundation

// Versioned, signed contact invitation. Contains public information only.
struct SpotchatContactCard: Codable, Equatable {
    var version = 1
    var noiseKey: Data
    var signingKey: Data
    var nostrKey: String
    var name: String
    var bio: String
    var signature = Data()
    var id: String { Self.userID(noiseKey) }
    var peerID: PeerID { PeerID(hexData: noiseKey) }
    static func userID(_ key: Data) -> String { SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() }
    func signedBytes() throws -> Data {
        var unsigned = self; unsigned.signature = Data()
        return try SpotchatCoding.encode(unsigned)
    }
    func validate() throws {
        guard version == 1, noiseKey.count == 32, signingKey.count == 32,
              noiseKey.contains(where: { $0 != 0 }), nostrKey.count == 64,
              nostrKey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 64, bio.count <= 72,
              try Curve25519.Signing.PublicKey(rawRepresentation: signingKey)
                .isValidSignature(signature, for: signedBytes()) else { throw SpotchatFailure.invalidContact }
    }
    func invitation() throws -> URL {
        let data = try SpotchatCoding.encode(self).base64EncodedString()
        var url = URLComponents(); url.scheme = "shum"; url.host = "contact"
        url.queryItems = [URLQueryItem(name: "data", value: data)]
        guard let result = url.url else { throw SpotchatFailure.invalidContact }
        return result
    }
    static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= 4096, url.scheme == "shum", url.host == "contact",
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "data" })?.value,
              let bytes = Data(base64Encoded: encoded), bytes.count <= 2048 else { throw SpotchatFailure.invalidContact }
        let card = try JSONDecoder().decode(Self.self, from: bytes); try card.validate(); return card
    }
}

enum SpotchatCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
enum SpotchatFailure: LocalizedError {
    case invalidContact, unavailableIdentity, invalidMessage, storage, quota, blocked
    var errorDescription: String? {
        switch self {
        case .invalidContact: return "Не удалось проверить контакт Shum. Попробуйте обменяться QR-кодами ещё раз."
        case .unavailableIdentity: return "Ключи профиля недоступны. Разблокируйте iPhone и снова откройте Shum."
        case .invalidMessage: return "Не удалось проверить сообщение."
        case .storage: return "Не удалось сохранить данные. Проверьте свободное место на iPhone."
        case .blocked: return "Контакт заблокирован. Сначала разблокируйте его в настройках профиля."
        case .quota: return "Очередь заполнена. Дождитесь доставки сообщений."
        }
    }
}

@MainActor
final class SpotchatIdentityService {
    let transport: Transport
    let nostr: NostrIdentity
    let storageKey: SymmetricKey
    init(transport: Transport, keychain: KeychainManagerProtocol, bridge: NostrIdentityBridge) throws {
        self.transport = transport
        // BLE initializes its Noise service lazily. Let the existing service
        // create first-launch keys before verifying their durable copies.
        let noisePublicKey = transport.noiseStaticPublicKeyData()
        let signingPublicKey = transport.noiseSigningPublicKeyData()
        // Upstream may temporarily generate an ephemeral identity when locked.
        // Never bind permanent contacts/history to that fallback identity.
        guard case .success(let raw) = keychain.getIdentityKeyWithResult(forKey: "noiseStaticKey"),
              try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw).publicKey.rawRepresentation == noisePublicKey,
              case .success(let signing) = keychain.getIdentityKeyWithResult(forKey: "ed25519SigningKey"),
              try Curve25519.Signing.PrivateKey(rawRepresentation: signing).publicKey.rawRepresentation == signingPublicKey else { throw SpotchatFailure.unavailableIdentity }
        let existing = keychain.loadWithResult(key: "nostr-current-identity", service: "chat.shum.nostr")
        switch existing {
        case .success(let data): nostr = try JSONDecoder().decode(NostrIdentity.self, from: data)
        case .itemNotFound:
            guard let generated = try bridge.getCurrentNostrIdentity(),
                  let saved = keychain.load(key: "nostr-current-identity", service: "chat.shum.nostr"),
                  try JSONDecoder().decode(NostrIdentity.self, from: saved).publicKey == generated.publicKey else { throw SpotchatFailure.unavailableIdentity }
            nostr = generated
        default: throw SpotchatFailure.unavailableIdentity
        }
        guard try NostrIdentity(privateKeyData: nostr.privateKey).publicKey == nostr.publicKey else { throw SpotchatFailure.unavailableIdentity }
        switch keychain.getIdentityKeyWithResult(forKey: "spotchatStorageKey") {
        case .success(let bytes):
            guard bytes.count == 32 else { throw SpotchatFailure.unavailableIdentity }
            storageKey = SymmetricKey(data: bytes)
        case .itemNotFound:
            let key = SymmetricKey(size: .bits256)
            let bytes = key.withUnsafeBytes { Data($0) }
            _ = keychain.saveIdentityKeyWithResult(bytes, forKey: "spotchatStorageKey")
            guard case .success(let saved) = keychain.getIdentityKeyWithResult(forKey: "spotchatStorageKey"), saved == bytes else { throw SpotchatFailure.unavailableIdentity }
            storageKey = key
        default: throw SpotchatFailure.unavailableIdentity
        }
    }
    func card(name: String, bio: String) throws -> SpotchatContactCard {
        var card = SpotchatContactCard(noiseKey: transport.noiseStaticPublicKeyData(), signingKey: transport.noiseSigningPublicKeyData(), nostrKey: nostr.publicKeyHex, name: name, bio: String(bio.prefix(72)))
        guard let signature = transport.noiseSignData(try card.signedBytes()) else { throw SpotchatFailure.unavailableIdentity }
        card.signature = signature; try card.validate(); return card
    }
}

protocol SpotchatSecureTransport: AnyObject {
    func sendSpotchatPacket(_ data: Data, to peer: PeerID)
    func sealSpotchatPayload(_ data: Data, recipient: Data) throws -> Data
    func openSpotchatPayload(_ data: Data) throws -> (payload: Data, senderStaticKey: Data)
}
extension BLEService: SpotchatSecureTransport {}

@MainActor
final class SpotchatCryptoService {
    private let wire: SpotchatSecureTransport
    init(wire: SpotchatSecureTransport) { self.wire = wire }
    func seal(_ data: Data, to recipient: Data) throws -> Data { try wire.sealSpotchatPayload(data, recipient: recipient) }
    func open(_ data: Data) throws -> (payload: Data, senderStaticKey: Data) { try wire.openSpotchatPayload(data) }
}
