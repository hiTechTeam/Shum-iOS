import BitFoundation
import CryptoKit
import Foundation

enum ShumIdentityKeyNames {
    static let storage = "shumStorageKey"
    static let legacyStorage = "spotchatStorageKey"
}

// Versioned, signed contact invitation. Contains public information only.
struct ShumContactCard: Codable, Equatable {
    var version = 1
    var noiseKey: Data
    var signingKey: Data
    var nostrKey: String
    var name: String
    var bio: String
    var signature = Data()
    var avatarSeed: UInt64?
    var avatarVersion: Int?
    var avatarSeedSignature: Data?
    var profileRevision: UInt64?
    var profileSignature: Data?
    var id: String { Self.userID(noiseKey) }
    var peerID: PeerID { PeerID(hexData: noiseKey) }
    static func userID(_ key: Data) -> String { SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() }
    func signedBytes() throws -> Data {
        var unsigned = self
        unsigned.signature = Data()
        // Keep the original card signature valid for older Shum versions.
        unsigned.profileRevision = nil
        unsigned.profileSignature = nil
        unsigned.avatarSeed = nil
        unsigned.avatarVersion = nil
        unsigned.avatarSeedSignature = nil
        return try ShumCoding.encode(unsigned)
    }
    func avatarSeedBytes() -> Data? {
        guard let avatarSeed, avatarVersion == ShumPixelAvatarGenerator.version else { return nil }
        var bytes = Data("shum.avatar-seed.v1\0".utf8)
        bytes.append(noiseKey)
        var littleEndianSeed = avatarSeed.littleEndian
        withUnsafeBytes(of: &littleEndianSeed) { bytes.append(contentsOf: $0) }
        return bytes
    }
    func profileBytes() throws -> Data {
        var unsigned = self
        unsigned.signature = Data()
        unsigned.avatarSeedSignature = nil
        unsigned.profileSignature = nil
        return Data("shum.profile.v1\0".utf8) + (try ShumCoding.encode(unsigned))
    }

    var profileID: String { (try? profileBytes()).map(Self.userID) ?? "" }

    /// Only compare authenticated cards with the same pinned identity.
    func preferred(over previous: Self) throws -> Self {
        try validate()
        guard noiseKey == previous.noiseKey, signingKey == previous.signingKey,
              nostrKey == previous.nostrKey else { throw ShumFailure.invalidContact }
        let incoming = profileRevision ?? 0, known = previous.profileRevision ?? 0
        if incoming != known { return incoming > known ? self : previous }
        // A deterministic tie-break converges after restoring an old backup.
        if incoming > 0 {
            if previous.profileID != profileID {
                return previous.profileID < profileID ? self : previous
            }
            // Prefer the complete transport card after first learning the same
            // authenticated profile through the compact QR representation.
            let incomingAuxiliarySignatures = (signature.isEmpty ? 0 : 1)
                + (avatarSeedSignature == nil ? 0 : 1)
            let previousAuxiliarySignatures = (previous.signature.isEmpty ? 0 : 1)
                + (previous.avatarSeedSignature == nil ? 0 : 1)
            return incomingAuxiliarySignatures > previousAuxiliarySignatures ? self : previous
        }
        return self
    }

    func validate() throws {
        guard version == 1, noiseKey.count == 32, signingKey.count == 32,
              noiseKey.contains(where: { $0 != 0 }), nostrKey.count == 64,
              nostrKey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.utf8.count <= 64, bio.count <= 72, bio.utf8.count <= 640 else {
            throw ShumFailure.invalidContact
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: signingKey)
        if let profileRevision {
            guard profileRevision > 0, avatarSeed != nil,
                  avatarVersion == ShumPixelAvatarGenerator.version,
                  let profileSignature, profileSignature.count == 64,
                  publicKey.isValidSignature(profileSignature, for: try profileBytes()) else {
                throw ShumFailure.invalidContact
            }
            if !signature.isEmpty,
               !publicKey.isValidSignature(signature, for: try signedBytes()) {
                throw ShumFailure.invalidContact
            }
            if let avatarSeedSignature {
                guard let signedSeed = avatarSeedBytes(), avatarSeedSignature.count == 64,
                      publicKey.isValidSignature(avatarSeedSignature, for: signedSeed) else {
                    throw ShumFailure.invalidContact
                }
            }
        } else {
            guard profileSignature == nil, signature.count == 64,
                  publicKey.isValidSignature(signature, for: try signedBytes()) else {
                throw ShumFailure.invalidContact
            }
            if avatarSeed != nil {
                guard let signedSeed = avatarSeedBytes(), let avatarSeedSignature,
                      avatarSeedSignature.count == 64,
                      publicKey.isValidSignature(avatarSeedSignature, for: signedSeed) else {
                    throw ShumFailure.invalidContact
                }
            } else if avatarVersion != nil || avatarSeedSignature != nil {
                throw ShumFailure.invalidContact
            }
        }
    }
    func invitation() throws -> URL {
        try validate()
        guard let seed = avatarSeed, let avatarVersion, let profileRevision,
              let profileSignature,
              let nostrBytes = Data(hexString: nostrKey) else {
            return try legacyInvitation()
        }
        // Binary c4 carries one signature over the complete public profile.
        // The transport-only signatures are redundant in a QR payload.
        var payload = Data([4, UInt8(version)])
        payload.append(noiseKey); payload.append(signingKey); payload.append(nostrBytes)
        payload.append(UInt8(name.utf8.count)); payload.append(contentsOf: name.utf8)
        payload.append(UInt8((bio.utf8.count >> 8) & 255))
        payload.append(UInt8(bio.utf8.count & 255)); payload.append(contentsOf: bio.utf8)
        func appendInteger(_ value: UInt64) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { payload.append(contentsOf: $0) }
        }
        appendInteger(seed)
        payload.append(UInt8(avatarVersion))
        appendInteger(profileRevision)
        payload.append(profileSignature)
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        guard let result = URL(string: "shum://c4/\(encoded)") else { throw ShumFailure.invalidContact }
        return result
    }

    /// HTTPS links are recognized by messengers. Keep the public profile in the
    /// fragment so opening the landing page does not send it to the server.
    /// The same signed payload is used by QR codes and links.
    func sharingInvitation(baseURL: URL? = nil) throws -> URL {
        let configuredURL = (Bundle.main.object(forInfoDictionaryKey: "ShumPushAPIBaseURL") as? String)
            .flatMap(URL.init(string:))
        guard let baseURL = baseURL ?? configuredURL,
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host?.isEmpty == false,
              components.user == nil, components.password == nil else {
            throw ShumFailure.invalidContact
        }
        let directURL = try invitation()
        components.path = "/invite"
        components.query = nil
        components.fragment = (directURL.host ?? "c4") + "/" + directURL.lastPathComponent
        guard let url = components.url else { throw ShumFailure.invalidContact }
        return url
    }

    /// Legacy self-contained invitation retained so QR codes created by older
    /// Shum builds continue to scan after the compact locator format ships.
    func legacyInvitation() throws -> URL {
        try validate()
        guard let nostrKey = Data(hexString: nostrKey), nostrKey.count == 32,
              signature.count == 64,
              name.utf8.count <= Int(UInt8.max),
              bio.utf8.count <= Int(UInt16.max) else {
            throw ShumFailure.invalidContact
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
            throw ShumFailure.invalidContact
        }
        return result
    }
    static func parse(_ url: URL) throws -> Self {
        guard url.absoluteString.utf8.count <= 4096, url.scheme == "shum" else {
            throw ShumFailure.invalidContact
        }
        if url.host == "c" || url.host == "c3" || url.host == "c4" {
            return try parseCompact(url)
        }
        guard url.host == "contact",
              let encoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "data" })?.value,
              let bytes = Data(base64Encoded: encoded), bytes.count <= 2048 else {
            throw ShumFailure.invalidContact
        }
        let card = try JSONDecoder().decode(Self.self, from: bytes)
        try card.validate()
        return card
    }

    private static func parseCompact(_ url: URL) throws -> Self {
        let encoded = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !encoded.isEmpty, encoded.utf8.count <= 2048 else {
            throw ShumFailure.invalidContact
        }
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: base64), bytes.count <= 1536 else {
            throw ShumFailure.invalidContact
        }

        var cursor = bytes.startIndex
        func read(_ count: Int) throws -> Data {
            guard count >= 0, cursor + count <= bytes.endIndex else {
                throw ShumFailure.invalidContact
            }
            defer { cursor += count }
            return Data(bytes[cursor ..< cursor + count])
        }
        func readByte() throws -> UInt8 {
            guard cursor < bytes.endIndex else { throw ShumFailure.invalidContact }
            defer { cursor += 1 }
            return bytes[cursor]
        }

        let format = try readByte()
        let expectedFormat = url.host == "c4" ? 4 : (url.host == "c3" ? 3 : 1)
        guard format == expectedFormat else { throw ShumFailure.invalidContact }
        let cardVersion = Int(try readByte())
        let noiseKey = try read(32)
        let signingKey = try read(32)
        let nostrKey = try read(32).hexEncodedString()
        let nameLength = Int(try readByte())
        let nameData = try read(nameLength)
        let bioLength = (Int(try readByte()) << 8) | Int(try readByte())
        let bioData = try read(bioLength)
        func readInteger() throws -> UInt64 {
            try read(8).enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        }
        let signature = format == 4 ? Data() : try read(64)
        let hasSeedProfile = format == 3 || format == 4
        let seed = hasSeedProfile ? try readInteger() : nil
        let avatarVersion = hasSeedProfile ? Int(try readByte()) : nil
        let revision = hasSeedProfile ? try readInteger() : nil
        let seedSignature = format == 3 ? try read(64) : nil
        let profileSignature = hasSeedProfile ? try read(64) : nil
        guard cursor == bytes.endIndex,
              let name = String(data: nameData, encoding: .utf8),
              let bio = String(data: bioData, encoding: .utf8) else {
            throw ShumFailure.invalidContact
        }

        let card = Self(
            version: cardVersion,
            noiseKey: noiseKey,
            signingKey: signingKey,
            nostrKey: nostrKey,
            name: name,
            bio: bio,
            signature: signature,
            avatarSeed: seed, avatarVersion: avatarVersion, avatarSeedSignature: seedSignature,
            profileRevision: revision, profileSignature: profileSignature
        )
        try card.validate()
        return card
    }
}

struct ShumContactLocator: Equatable {
    let nostrKey: String

    init(nostrKey: String) throws {
        guard nostrKey.count == 64,
              nostrKey.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              Data(hexString: nostrKey)?.count == 32 else {
            throw ShumFailure.invalidContact
        }
        self.nostrKey = nostrKey
    }

    fileprivate static func parse(_ url: URL) throws -> Self {
        guard url.scheme == "shum", url.host == "c2" else {
            throw ShumFailure.invalidContact
        }
        let encoded = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard encoded.utf8.count == 43 else { throw ShumFailure.invalidContact }
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += "="
        guard let key = Data(base64Encoded: base64), key.count == 32 else {
            throw ShumFailure.invalidContact
        }
        return try Self(nostrKey: key.hexEncodedString())
    }
}

enum ShumInvitationPayload {
    case card(ShumContactCard)
    case locator(ShumContactLocator)

    static func parse(_ url: URL) throws -> Self {
        if url.scheme == "https", url.path == "/invite", url.absoluteString.utf8.count <= 4096,
           let fragment = url.fragment, let direct = URL(string: "shum://" + fragment) {
            return try parse(direct)
        }
        if url.scheme == "shum", url.host == "c2" {
            return .locator(try ShumContactLocator.parse(url))
        }
        return .card(try ShumContactCard.parse(url))
    }
}

enum ShumCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
enum ShumFailure: LocalizedError {
    case invalidContact, contactUnavailable, unavailableIdentity, invalidMessage, storage, quota, blocked
    var errorDescription: String? {
        switch self {
        case .invalidContact: return "Не удалось проверить контакт Shum. Попробуйте обменяться QR-кодами ещё раз.".localized
        case .contactUnavailable: return "Не удалось получить контакт. Убедитесь, что второе устройство находится рядом или подключено к Nostr.".localized
        case .unavailableIdentity: return "Ключи профиля недоступны. Разблокируйте iPhone и снова откройте Shum.".localized
        case .invalidMessage: return "Не удалось проверить сообщение.".localized
        case .storage: return "Не удалось сохранить данные. Проверьте свободное место на iPhone.".localized
        case .blocked: return "Контакт заблокирован. Сначала разблокируйте его в настройках профиля.".localized
        case .quota: return "Очередь заполнена. Дождитесь доставки сообщений.".localized
        }
    }
}

@MainActor
final class ShumIdentityService {
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
              try Curve25519.Signing.PrivateKey(rawRepresentation: signing).publicKey.rawRepresentation == signingPublicKey else { throw ShumFailure.unavailableIdentity }
        let existing = keychain.loadWithResult(key: "nostr-current-identity", service: "chat.shum.nostr")
        switch existing {
        case .success(let data): nostr = try JSONDecoder().decode(NostrIdentity.self, from: data)
        case .itemNotFound:
            guard let generated = try bridge.getCurrentNostrIdentity(),
                  let saved = keychain.load(key: "nostr-current-identity", service: "chat.shum.nostr"),
                  try JSONDecoder().decode(NostrIdentity.self, from: saved).publicKey == generated.publicKey else { throw ShumFailure.unavailableIdentity }
            nostr = generated
        default: throw ShumFailure.unavailableIdentity
        }
        guard try NostrIdentity(privateKeyData: nostr.privateKey).publicKey == nostr.publicKey else { throw ShumFailure.unavailableIdentity }
        let storageBytes: Data
        switch keychain.getIdentityKeyWithResult(
            forKey: ShumIdentityKeyNames.storage
        ) {
        case .success(let bytes):
            storageBytes = bytes
        case .itemNotFound:
            if case .success(let legacyBytes) = keychain
                .getIdentityKeyWithResult(
                    forKey: ShumIdentityKeyNames.legacyStorage
                ) {
                guard case .success = keychain.saveIdentityKeyWithResult(
                    legacyBytes,
                    forKey: ShumIdentityKeyNames.storage
                ) else { throw ShumFailure.unavailableIdentity }
                storageBytes = legacyBytes
                break
            }
            let key = SymmetricKey(size: .bits256)
            let bytes = key.withUnsafeBytes { Data($0) }
            _ = keychain.saveIdentityKeyWithResult(
                bytes,
                forKey: ShumIdentityKeyNames.storage
            )
            guard case .success(let saved) = keychain
                .getIdentityKeyWithResult(
                    forKey: ShumIdentityKeyNames.storage
                ), saved == bytes else {
                throw ShumFailure.unavailableIdentity
            }
            storageBytes = bytes
        default: throw ShumFailure.unavailableIdentity
        }
        guard storageBytes.count == 32 else {
            throw ShumFailure.unavailableIdentity
        }
        storageKey = SymmetricKey(data: storageBytes)
    }
    func card(name: String, bio: String, avatarSeed: UInt64? = nil, revision: UInt64 = 1) throws -> ShumContactCard {
        var card = ShumContactCard(noiseKey: transport.noiseStaticPublicKeyData(), signingKey: transport.noiseSigningPublicKeyData(), nostrKey: nostr.publicKeyHex, name: name, bio: String(bio.prefix(72)))
        guard let signature = transport.noiseSignData(try card.signedBytes()) else { throw ShumFailure.unavailableIdentity }
        card.signature = signature
        card.avatarSeed = avatarSeed ?? ShumPixelAvatarGenerator.seed(for: card.noiseKey)
        card.avatarVersion = ShumPixelAvatarGenerator.version
        guard let signedSeed = card.avatarSeedBytes(),
              let seedSignature = transport.noiseSignData(signedSeed) else {
            throw ShumFailure.unavailableIdentity
        }
        card.avatarSeedSignature = seedSignature
        card.profileRevision = revision
        guard let profileSignature = transport.noiseSignData(try card.profileBytes()) else {
            throw ShumFailure.unavailableIdentity
        }
        card.profileSignature = profileSignature
        try card.validate()
        return card
    }
}

protocol ShumSecureTransport: AnyObject {
    func sendShumPacket(_ data: Data, to peer: PeerID)
    func sealShumPayload(_ data: Data, recipient: Data) throws -> Data
    func openShumPayload(_ data: Data) throws -> (payload: Data, senderStaticKey: Data)
}
extension BLEService: ShumSecureTransport {}

@MainActor
final class ShumCryptoService {
    private let wire: ShumSecureTransport
    init(wire: ShumSecureTransport) { self.wire = wire }
    func seal(_ data: Data, to recipient: Data) throws -> Data { try wire.sealShumPayload(data, recipient: recipient) }
    func open(_ data: Data) throws -> (payload: Data, senderStaticKey: Data) { try wire.openShumPayload(data) }
}
