import BitFoundation
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

extension UTType {
    static let shumBackup = UTType(
        exportedAs: "hiTeam.ShumiOS.backup",
        conformingTo: .data
    )
}

enum ShumBackupError: LocalizedError {
    case profileUnavailable
    case protectedDataUnavailable
    case invalidPassword
    case invalidBackup
    case backupTooLarge
    case restoreRequiresEmptyProfile
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .profileUnavailable:
            return "Профиль ещё не готов для создания резервной копии."
        case .protectedDataUnavailable:
            return "Не удалось прочитать защищённые ключи. Разблокируйте устройство и попробуйте ещё раз."
        case .invalidPassword:
            return "Неверный пароль или файл резервной копии повреждён."
        case .invalidBackup:
            return "Shum не смог проверить эту резервную копию."
        case .backupTooLarge:
            return "Резервная копия слишком большая или повреждена."
        case .restoreRequiresEmptyProfile:
            return "Восстановление доступно только до создания нового профиля."
        case .couldNotSave:
            return "Не удалось сохранить восстановленные данные на устройстве."
        }
    }
}

struct ShumBackupMetadata {
    let profileName: String
    let createdAt: Date
}

final class ShumBackupService {
    static let shared = ShumBackupService()

    static let minimumPasswordLength = 10
    static let lastBackupDateKey = "shum.backup.lastCreatedAt"

    private static let magic = Data("SHUM-BACKUP-1\n".utf8)
    private static let associatedData = Data("hiTeam.ShumiOS.backup.v1".utf8)
    private static let iterations = 210_000
    private static let maximumPlaintextBytes = 130 * 1024 * 1024
    private static let maximumFileBytes = 100 * 1024 * 1024

    private let files = FileManager.default
    private let localCardSigningKey = "shum.local-card.signing-key.v1"
    private let legacyChatStorageKey = "shum.chat.storage-key"
    private let nostrService = "chat.shum.nostr"
    private let nostrIdentityKey = "nostr-current-identity"
    private let nostrDeviceSeedKey = "nostr-device-seed"

    private struct KeyMaterial: Codable {
        let localCardSigning: Data
        let noiseStatic: Data
        let noiseSigning: Data
        let nostrIdentity: Data
        let shumStorage: Data
        let nostrDeviceSeed: Data?
        let identityCacheEncryption: Data?
        let identityCache: Data?
        let legacyChatStorage: Data?

        private enum CodingKeys: String, CodingKey {
            case localCardSigning
            case noiseStatic
            case noiseSigning
            case nostrIdentity
            case shumStorage
            case legacyMessagingStorage = "spotchatStorage"
            case nostrDeviceSeed
            case identityCacheEncryption
            case identityCache
            case legacyChatStorage
        }

        init(
            localCardSigning: Data,
            noiseStatic: Data,
            noiseSigning: Data,
            nostrIdentity: Data,
            shumStorage: Data,
            nostrDeviceSeed: Data?,
            identityCacheEncryption: Data?,
            identityCache: Data?,
            legacyChatStorage: Data?
        ) {
            self.localCardSigning = localCardSigning
            self.noiseStatic = noiseStatic
            self.noiseSigning = noiseSigning
            self.nostrIdentity = nostrIdentity
            self.shumStorage = shumStorage
            self.nostrDeviceSeed = nostrDeviceSeed
            self.identityCacheEncryption = identityCacheEncryption
            self.identityCache = identityCache
            self.legacyChatStorage = legacyChatStorage
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            localCardSigning = try values.decode(Data.self, forKey: .localCardSigning)
            noiseStatic = try values.decode(Data.self, forKey: .noiseStatic)
            noiseSigning = try values.decode(Data.self, forKey: .noiseSigning)
            nostrIdentity = try values.decode(Data.self, forKey: .nostrIdentity)
            shumStorage = try values.decodeIfPresent(Data.self, forKey: .shumStorage)
                ?? values.decode(Data.self, forKey: .legacyMessagingStorage)
            nostrDeviceSeed = try values.decodeIfPresent(Data.self, forKey: .nostrDeviceSeed)
            identityCacheEncryption = try values.decodeIfPresent(Data.self, forKey: .identityCacheEncryption)
            identityCache = try values.decodeIfPresent(Data.self, forKey: .identityCache)
            legacyChatStorage = try values.decodeIfPresent(Data.self, forKey: .legacyChatStorage)
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(localCardSigning, forKey: .localCardSigning)
            try values.encode(noiseStatic, forKey: .noiseStatic)
            try values.encode(noiseSigning, forKey: .noiseSigning)
            try values.encode(nostrIdentity, forKey: .nostrIdentity)
            try values.encode(shumStorage, forKey: .shumStorage)
            try values.encodeIfPresent(nostrDeviceSeed, forKey: .nostrDeviceSeed)
            try values.encodeIfPresent(identityCacheEncryption, forKey: .identityCacheEncryption)
            try values.encodeIfPresent(identityCache, forKey: .identityCache)
            try values.encodeIfPresent(legacyChatStorage, forKey: .legacyChatStorage)
        }
    }

    private struct StoredFile: Codable {
        let path: String
        let data: Data
    }

    private struct Payload: Codable {
        let version: Int
        let createdAt: Date
        let profileName: String
        let keys: KeyMaterial
        let storedFiles: [StoredFile]
    }

    private struct Envelope: Codable {
        let version: Int
        let createdAt: Date
        let profileName: String
        let salt: Data
        let iterations: Int
        let ciphertext: Data
    }

    func create(password: String) async throws -> Data {
        guard Self.validPassword(password) else {
            throw ShumBackupError.invalidPassword
        }

        let payload = try collectPayload()
        let plaintext = try JSONEncoder().encode(payload)
        guard plaintext.count <= Self.maximumPlaintextBytes else {
            throw ShumBackupError.backupTooLarge
        }

        let createdAt = payload.createdAt
        let profileName = payload.profileName
        return try await Task.detached(priority: .userInitiated) {
            try Self.encrypt(
                plaintext,
                password: password,
                createdAt: createdAt,
                profileName: profileName
            )
        }.value
    }

    func metadata(for data: Data) throws -> ShumBackupMetadata {
        let envelope = try Self.decodeEnvelope(data)
        return ShumBackupMetadata(
            profileName: envelope.profileName,
            createdAt: envelope.createdAt
        )
    }

    func restore(data: Data, password: String) async throws -> ShumBackupMetadata {
        guard LocalCardStore.shared.ownManifest == nil else {
            throw ShumBackupError.restoreRequiresEmptyProfile
        }
        guard Self.validPassword(password) else {
            throw ShumBackupError.invalidPassword
        }

        let payloadData = try await Task.detached(priority: .userInitiated) {
            try Self.decrypt(data, password: password)
        }.value
        guard payloadData.count <= Self.maximumPlaintextBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData) else {
            throw ShumBackupError.invalidBackup
        }

        try validate(payload)
        try install(payload)
        return ShumBackupMetadata(
            profileName: payload.profileName,
            createdAt: payload.createdAt
        )
    }

    private func collectPayload() throws -> Payload {
        guard let manifest = LocalCardStore.shared.ownManifest else {
            throw ShumBackupError.profileUnavailable
        }

        let keychain = KeychainManager.makeDefault()
        let material = KeyMaterial(
            localCardSigning: try requiredLocalKey(localCardSigningKey),
            noiseStatic: try requiredIdentityKey("noiseStaticKey", keychain: keychain),
            noiseSigning: try requiredIdentityKey("ed25519SigningKey", keychain: keychain),
            nostrIdentity: try requiredCustomKey(
                nostrIdentityKey,
                service: nostrService,
                keychain: keychain
            ),
            shumStorage: try requiredShumStorageKey(keychain: keychain),
            nostrDeviceSeed: optionalCustomKey(
                nostrDeviceSeedKey,
                service: nostrService,
                keychain: keychain
            ),
            identityCacheEncryption: optionalIdentityKey(
                "identityCacheEncryptionKey",
                keychain: keychain
            ),
            identityCache: optionalIdentityKey(
                "bitchat.identityCache.v2",
                keychain: keychain
            ),
            legacyChatStorage: try? KeychainStore.shared.data(for: legacyChatStorageKey)
        )

        return Payload(
            version: 1,
            createdAt: Date(),
            profileName: manifest.body.name,
            keys: material,
            storedFiles: try collectFiles()
        )
    }

    private func collectFiles() throws -> [StoredFile] {
        let support = supportDirectory
        var result: [StoredFile] = []

        try appendDirectory(
            support.appendingPathComponent("LocalCards-v1", isDirectory: true),
            prefix: "LocalCards-v1",
            to: &result
        )
        try appendDirectory(
            support.appendingPathComponent("ShumProfiles", isDirectory: true),
            prefix: "ShumProfiles",
            to: &result
        )
        try appendFile(
            support.appendingPathComponent("ShumConversations/state.enc"),
            path: "ShumConversations/state.enc",
            required: false,
            to: &result
        )
        try appendFile(
            support.appendingPathComponent("shum-chats-v1.enc"),
            path: "shum-chats-v1.enc",
            required: false,
            to: &result
        )

        guard result.contains(where: { $0.path == "LocalCards-v1/own.json" }) else {
            throw ShumBackupError.profileUnavailable
        }
        return result.sorted { $0.path < $1.path }
    }

    private func appendDirectory(
        _ directory: URL,
        prefix: String,
        to result: inout [StoredFile]
    ) throws {
        guard files.fileExists(atPath: directory.path) else { return }
        let entries = try files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        for url in entries {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let name = url.lastPathComponent
            guard Self.allowedFileName(name, in: prefix) else { continue }
            try appendFile(url, path: "\(prefix)/\(name)", required: false, to: &result)
        }
    }

    private func appendFile(
        _ url: URL,
        path: String,
        required: Bool,
        to result: inout [StoredFile]
    ) throws {
        guard files.fileExists(atPath: url.path) else {
            if required { throw ShumBackupError.profileUnavailable }
            return
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 0, size <= Self.maximumFileBytes else {
            throw ShumBackupError.backupTooLarge
        }
        result.append(StoredFile(path: path, data: try Data(contentsOf: url)))
    }

    private func validate(_ payload: Payload) throws {
        guard payload.version == 1,
              !payload.profileName.isEmpty,
              payload.profileName.utf8.count <= 256,
              payload.storedFiles.count <= 600,
              Set(payload.storedFiles.map(\.path)).count == payload.storedFiles.count,
              payload.storedFiles.allSatisfy({
                  $0.data.count <= Self.maximumFileBytes && Self.allowedPath($0.path)
              }),
              payload.keys.localCardSigning.count == 32,
              payload.keys.noiseStatic.count == 32,
              payload.keys.noiseSigning.count == 32,
              payload.keys.shumStorage.count == 32 else {
            throw ShumBackupError.invalidBackup
        }

        let fileMap = Dictionary(
            uniqueKeysWithValues: payload.storedFiles.map { ($0.path, $0.data) }
        )
        guard let ownData = fileMap["LocalCards-v1/own.json"],
              let manifest = try? JSONDecoder().decode(LocalCardManifest.self, from: ownData),
              (try? manifest.validate()) != nil,
              manifest.body.name == payload.profileName else {
            throw ShumBackupError.invalidBackup
        }

        let localPrivate = try Curve25519.Signing.PrivateKey(
            rawRepresentation: payload.keys.localCardSigning
        )
        guard localPrivate.publicKey.rawRepresentation == manifest.publicKey else {
            throw ShumBackupError.invalidBackup
        }

        let noisePrivate = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: payload.keys.noiseStatic
        )
        let noiseSigningPrivate = try Curve25519.Signing.PrivateKey(
            rawRepresentation: payload.keys.noiseSigning
        )
        guard let nostr = try? JSONDecoder().decode(
            NostrIdentity.self,
            from: payload.keys.nostrIdentity
        ), let verifiedNostr = try? NostrIdentity(privateKeyData: nostr.privateKey),
              verifiedNostr.publicKey == nostr.publicKey else {
            throw ShumBackupError.invalidBackup
        }

        if let photoHash = manifest.body.photoHash {
            guard let photo = fileMap["LocalCards-v1/\(photoHash).jpg"],
                  LocalCardPhoto.hash(photo) == photoHash,
                  LocalCardPhoto.validate(photo) else {
                throw ShumBackupError.invalidBackup
            }
        }

        if let profileData = fileMap["ShumProfiles/own.json"] {
            guard let profile = try? JSONDecoder().decode(ShumProfile.self, from: profileData),
                  profile.valid else {
                throw ShumBackupError.invalidBackup
            }
        }

        if let encryptedHistory = fileMap["ShumConversations/state.enc"] {
            let key = SymmetricKey(data: payload.keys.shumStorage)
            guard let box = try? ChaChaPoly.SealedBox(combined: encryptedHistory),
                  let plaintext = try? ChaChaPoly.open(box, using: key),
                  let database = try? JSONDecoder().decode(ShumDatabase.self, from: plaintext),
                  database.version == 1,
                  database.ownerID == ShumContactCard.userID(
                    noisePrivate.publicKey.rawRepresentation
                  ) else {
                throw ShumBackupError.invalidBackup
            }

            let ownID = database.ownerID
            let ownNoiseKey = noisePrivate.publicKey.rawRepresentation
            let ownSigningKey = noiseSigningPrivate.publicKey.rawRepresentation
            let cards = database.messages.flatMap {
                [$0.envelope.sender, $0.envelope.recipient]
            } + database.relay.flatMap {
                [$0.envelope.sender, $0.envelope.recipient]
            } + database.receipts.flatMap {
                [$0.receipt.sender, $0.receipt.destination]
            }
            for card in cards where card.id == ownID {
                guard card.noiseKey == ownNoiseKey,
                      card.signingKey == ownSigningKey,
                      card.nostrKey == verifiedNostr.publicKeyHex,
                      (try? card.validate()) != nil else {
                    throw ShumBackupError.invalidBackup
                }
            }
        }

        if let legacyHistory = fileMap["shum-chats-v1.enc"] {
            guard let legacyKey = payload.keys.legacyChatStorage,
                  legacyKey.count == 32,
                  let box = try? AES.GCM.SealedBox(combined: legacyHistory),
                  let plaintext = try? AES.GCM.open(
                    box,
                    using: SymmetricKey(data: legacyKey)
                  ),
                  (try? JSONDecoder().decode(ShumLegacyArchive.self, from: plaintext)) != nil else {
                throw ShumBackupError.invalidBackup
            }
        }
    }

    private func install(_ payload: Payload) throws {
        let keychain = KeychainManager.makeDefault()
        var installedPaths: [URL] = []

        do {
            for stored in payload.storedFiles {
                let target = supportDirectory.appendingPathComponent(stored.path)
                try files.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try stored.data.write(
                    to: target,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
                installedPaths.append(target)
            }

            try KeychainStore.shared.set(
                payload.keys.localCardSigning,
                for: localCardSigningKey
            )
            try saveIdentityKey(payload.keys.noiseStatic, name: "noiseStaticKey", keychain: keychain)
            try saveIdentityKey(payload.keys.noiseSigning, name: "ed25519SigningKey", keychain: keychain)
            try saveIdentityKey(
                payload.keys.shumStorage,
                name: ShumIdentityKeyNames.storage,
                keychain: keychain
            )
            if let value = payload.keys.identityCacheEncryption {
                try saveIdentityKey(value, name: "identityCacheEncryptionKey", keychain: keychain)
            }
            if let value = payload.keys.identityCache {
                try saveIdentityKey(value, name: "bitchat.identityCache.v2", keychain: keychain)
            }

            try saveCustomKey(
                payload.keys.nostrIdentity,
                name: nostrIdentityKey,
                service: nostrService,
                keychain: keychain
            )
            if let value = payload.keys.nostrDeviceSeed {
                try saveCustomKey(
                    value,
                    name: nostrDeviceSeedKey,
                    service: nostrService,
                    keychain: keychain
                )
            }
            if let value = payload.keys.legacyChatStorage {
                try KeychainStore.shared.set(value, for: legacyChatStorageKey)
            }

            UserDefaults.standard.set(payload.profileName, forKey: "shum.nickname")
            LocalCardStore.shared.reloadFromDisk()
            guard LocalCardStore.shared.ownManifest != nil else {
                throw ShumBackupError.couldNotSave
            }
        } catch {
            for path in installedPaths { try? files.removeItem(at: path) }
            try? KeychainStore.shared.remove(localCardSigningKey)
            try? KeychainStore.shared.remove(legacyChatStorageKey)
            _ = keychain.deleteIdentityKey(forKey: "noiseStaticKey")
            _ = keychain.deleteIdentityKey(forKey: "ed25519SigningKey")
            _ = keychain.deleteIdentityKey(
                forKey: ShumIdentityKeyNames.storage
            )
            _ = keychain.deleteIdentityKey(forKey: "identityCacheEncryptionKey")
            _ = keychain.deleteIdentityKey(forKey: "bitchat.identityCache.v2")
            keychain.delete(key: nostrIdentityKey, service: nostrService)
            keychain.delete(key: nostrDeviceSeedKey, service: nostrService)
            LocalCardStore.shared.reloadFromDisk()
            throw error
        }
    }

    private func requiredLocalKey(_ name: String) throws -> Data {
        guard let value = try KeychainStore.shared.data(for: name) else {
            throw ShumBackupError.protectedDataUnavailable
        }
        return value
    }

    private func requiredIdentityKey(
        _ name: String,
        keychain: KeychainManagerProtocol
    ) throws -> Data {
        guard case .success(let value) = keychain.getIdentityKeyWithResult(forKey: name) else {
            throw ShumBackupError.protectedDataUnavailable
        }
        return value
    }

    private func requiredShumStorageKey(
        keychain: KeychainManagerProtocol
    ) throws -> Data {
        if case .success(let value) = keychain.getIdentityKeyWithResult(
            forKey: ShumIdentityKeyNames.storage
        ) {
            return value
        }
        if case .success(let value) = keychain.getIdentityKeyWithResult(
            forKey: ShumIdentityKeyNames.legacyStorage
        ) {
            return value
        }
        throw ShumBackupError.protectedDataUnavailable
    }

    private func optionalIdentityKey(
        _ name: String,
        keychain: KeychainManagerProtocol
    ) -> Data? {
        guard case .success(let value) = keychain.getIdentityKeyWithResult(forKey: name) else {
            return nil
        }
        return value
    }

    private func requiredCustomKey(
        _ name: String,
        service: String,
        keychain: KeychainManagerProtocol
    ) throws -> Data {
        guard case .success(let value) = keychain.loadWithResult(key: name, service: service) else {
            throw ShumBackupError.protectedDataUnavailable
        }
        return value
    }

    private func optionalCustomKey(
        _ name: String,
        service: String,
        keychain: KeychainManagerProtocol
    ) -> Data? {
        guard case .success(let value) = keychain.loadWithResult(key: name, service: service) else {
            return nil
        }
        return value
    }

    private func saveIdentityKey(
        _ value: Data,
        name: String,
        keychain: KeychainManagerProtocol
    ) throws {
        guard case .success = keychain.saveIdentityKeyWithResult(value, forKey: name),
              case .success(let verified) = keychain.getIdentityKeyWithResult(forKey: name),
              verified == value else {
            throw ShumBackupError.couldNotSave
        }
    }

    private func saveCustomKey(
        _ value: Data,
        name: String,
        service: String,
        keychain: KeychainManagerProtocol
    ) throws {
        keychain.save(key: name, data: value, service: service, accessible: nil)
        guard case .success(let verified) = keychain.loadWithResult(key: name, service: service),
              verified == value else {
            throw ShumBackupError.couldNotSave
        }
    }

    private var supportDirectory: URL {
        files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    nonisolated private static func validPassword(_ password: String) -> Bool {
        password.count >= minimumPasswordLength && password.utf8.count <= 256
    }

    nonisolated private static func allowedPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("..") else { return false }
        if components.count == 1 {
            return components[0] == "shum-chats-v1.enc"
        }
        guard components.count == 2 else { return false }
        let directory = String(components[0])
        let name = String(components[1])
        if directory == "ShumConversations" { return name == "state.enc" }
        return allowedFileName(name, in: directory)
    }

    nonisolated private static func allowedFileName(_ name: String, in directory: String) -> Bool {
        switch directory {
        case "LocalCards-v1":
            if name == "own.json" || name == "peers.json" { return true }
        case "ShumProfiles":
            if name == "own.json" { return true }
        default:
            return false
        }
        guard name.hasSuffix(".jpg") else { return false }
        return LocalCardPhoto.validHash(String(name.dropLast(4)))
    }

    nonisolated private static func encrypt(
        _ plaintext: Data,
        password: String,
        createdAt: Date,
        profileName: String
    ) throws -> Data {
        let salt = try randomData(count: 16)
        let key = deriveKey(password: password, salt: salt, iterations: iterations)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
        guard let combined = sealed.combined else { throw ShumBackupError.invalidBackup }
        let envelope = Envelope(
            version: 1,
            createdAt: createdAt,
            profileName: profileName,
            salt: salt,
            iterations: iterations,
            ciphertext: combined
        )
        return magic + (try JSONEncoder().encode(envelope))
    }

    nonisolated private static func decrypt(_ data: Data, password: String) throws -> Data {
        let envelope = try decodeEnvelope(data)
        guard envelope.version == 1,
              (100_000...1_000_000).contains(envelope.iterations),
              envelope.salt.count == 16,
              envelope.ciphertext.count <= maximumPlaintextBytes + 64 else {
            throw ShumBackupError.invalidBackup
        }
        let key = deriveKey(
            password: password,
            salt: envelope.salt,
            iterations: envelope.iterations
        )
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.ciphertext)
            return try AES.GCM.open(box, using: key, authenticating: associatedData)
        } catch {
            throw ShumBackupError.invalidPassword
        }
    }

    nonisolated private static func decodeEnvelope(_ data: Data) throws -> Envelope {
        guard data.count > magic.count,
              data.count <= maximumPlaintextBytes + 1_000_000,
              data.prefix(magic.count) == magic,
              let envelope = try? JSONDecoder().decode(
                Envelope.self,
                from: data.dropFirst(magic.count)
              ) else {
            throw ShumBackupError.invalidBackup
        }
        return envelope
    }

    nonisolated private static func randomData(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ShumBackupError.couldNotSave
        }
        return Data(bytes)
    }

    nonisolated private static func deriveKey(
        password: String,
        salt: Data,
        iterations: Int
    ) -> SymmetricKey {
        let normalized = password.precomposedStringWithCanonicalMapping
        let passwordKey = SymmetricKey(data: Data(normalized.utf8))
        var blockInput = salt
        var blockIndex = UInt32(1).bigEndian
        withUnsafeBytes(of: &blockIndex) { blockInput.append(contentsOf: $0) }

        var current = Data(
            HMAC<SHA256>.authenticationCode(for: blockInput, using: passwordKey)
        )
        var result = current
        if iterations > 1 {
            for _ in 1..<iterations {
                current = Data(
                    HMAC<SHA256>.authenticationCode(for: current, using: passwordKey)
                )
                let resultCount = result.count
                result.withUnsafeMutableBytes { resultBytes in
                    current.withUnsafeBytes { currentBytes in
                        guard let resultBase = resultBytes.bindMemory(to: UInt8.self).baseAddress,
                              let currentBase = currentBytes.bindMemory(to: UInt8.self).baseAddress else {
                            return
                        }
                        for index in 0..<resultCount {
                            resultBase[index] ^= currentBase[index]
                        }
                    }
                }
            }
        }
        return SymmetricKey(data: result.prefix(32))
    }
}
