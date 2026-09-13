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
        try validate()
        guard let nostrKey = Data(hexString: nostrKey), nostrKey.count == 32,
              signature.count == 64,
              name.utf8.count <= Int(UInt8.max),
              bio.utf8.count <= Int(UInt16.max) else {
            throw SpotchatFailure.invalidContact
        }

        var payload = Data([1, UInt8(version)])
        payload.append(noiseKey)
        payload.append(signingKey)
        payload.append(nostrKey)
        payload.append(UInt8(name.utf8.count))
        payload.append(contentsOf: name.utf8)
        payload.append(UInt8((bio.utf8.count >> 8) & 0xff))
        payload.append(UInt8(bio.utf8.count & 0xff))
        payload.append(contentsOf: bio.utf8)
        payload.append(signature)

        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let result = URL(string: "shum://c/\(encoded)") else {
            throw SpotchatFailure.invalidContact
        }
        return result
    }
    static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= 4096, url.scheme == "shum" else {
            throw SpotchatFailure.invalidContact
        }
        if url.host == "c" {
            return try parseCompact(url)
        }
        guard url.host == "contact",
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "data" })?.value,
              let bytes = Data(base64Encoded: encoded), bytes.count <= 2048 else {
            throw SpotchatFailure.invalidContact
        }
        let card = try JSONDecoder().decode(Self.self, from: bytes)
        try card.validate()
        return card
    }

    private static func parseCompact(_ url: URL) throws -> Self {
        let encoded = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !encoded.isEmpty, encoded.utf8.count <= 1024 else {
            throw SpotchatFailure.invalidContact
        }
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), bytes.count <= 768 else {
            throw SpotchatFailure.invalidContact
        }

        var cursor = bytes.startIndex
        func read(_ count: Int) throws -> Data {
            guard count >= 0, cursor + count <= bytes.endIndex else {
                throw SpotchatFailure.invalidContact
            }
            defer { cursor += count }
            return Data(bytes[cursor ..< cursor + count])
        }
        func readByte() throws -> UInt8 {
            guard cursor < bytes.endIndex else { throw SpotchatFailure.invalidContact }
            defer { cursor += 1 }
            return bytes[cursor]
        }

        guard try readByte() == 1 else { throw SpotchatFailure.invalidContact }
        let cardVersion = Int(try readByte())
        let noiseKey = try read(32)
        let signingKey = try read(32)
        let nostrKey = try read(32).hexEncodedString()
        let nameLength = Int(try readByte())
        let nameData = try read(nameLength)
        let bioLength = (Int(try readByte()) << 8) | Int(try readByte())
        let bioData = try read(bioLength)
        let signature = try read(64)
        guard cursor == bytes.endIndex,
              let name = String(data: nameData, encoding: .utf8),
              let bio = String(data: bioData, encoding: .utf8) else {
            throw SpotchatFailure.invalidContact
        }

        let card = Self(
            version: cardVersion,
            noiseKey: noiseKey,
            signingKey: signingKey,
            nostrKey: nostrKey,
            name: name,
            bio: bio,
            signature: signature
        )
        try card.validate()
        return card
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
