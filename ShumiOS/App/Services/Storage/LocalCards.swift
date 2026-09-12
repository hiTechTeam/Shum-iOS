import CryptoKit
import Foundation
import ImageIO
import UIKit

enum LocalCardError: Error {
    case invalidProfile, invalidPhoto, unavailable, invalidPacket
}

struct LocalCardBody: Codable, Equatable {
    var version = 1
    let id: UUID
    let name: String
    let username: String
    let bio: String?
    let photoHash: String?
    let photoBytes: Int
}

struct LocalCardManifest: Codable, Equatable {
    let body: LocalCardBody
    let publicKey: Data
    let signature: Data

    static func encodedBody(_ body: LocalCardBody) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    static func identity(for publicKey: Data) -> UUID {
        let hex = LocalCardPhoto.hash(publicKey)
        let s = Array(hex.prefix(32))
        return UUID(uuidString: "\(String(s[0..<8]))-\(String(s[8..<12]))-\(String(s[12..<16]))-\(String(s[16..<20]))-\(String(s[20..<32]))")!
    }

    func validate() throws {
        guard [1, 2].contains(body.version), body.id == Self.identity(for: publicKey),
              (body.version == 1 ? Self.username(body.username) == body.username : body.username.isEmpty),
              !body.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              body.name.count <= 64, body.name.utf8.count <= 256,
              !body.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (body.bio?.count ?? 0) <= 36,
              body.photoBytes >= 0, body.photoBytes <= LocalCardPhoto.maximumBytes,
              body.photoHash.map({ LocalCardPhoto.validHash($0) && body.photoBytes > 0 })
                ?? (body.photoBytes == 0),
              publicKey.count == 32, signature.count == 64 else {
            throw LocalCardError.invalidProfile
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signature, for: try Self.encodedBody(body)) else {
            throw LocalCardError.invalidProfile
        }
    }

    static func username(_ value: String) -> String? {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("@") { value.removeFirst() }
        guard (5...32).contains(value.count),
              let first = value.first, first.isASCII, first.isLetter,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { return nil }
        return value
    }
}

enum LocalCardPhoto {
    static let maximumBytes = 40 * 1024
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func validHash(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }
    static func validate(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = info[kCGImagePropertyPixelWidth] as? Int,
              let h = info[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 360, h <= 360 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
    @MainActor static func prepare(_ image: UIImage) throws -> Data {
        guard image.size.width > 0, image.size.height > 0 else { throw LocalCardError.invalidPhoto }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let square = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 360), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 360, height: 360))
            let scale = 360 / min(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (360 - size.width) / 2, y: (360 - size.height) / 2, width: size.width, height: size.height))
        }
        for quality in [0.88, 0.75, 0.6, 0.45, 0.3, 0.18] {
            if let data = square.jpegData(compressionQuality: quality), validate(data) { return data }
        }
        throw LocalCardError.invalidPhoto
    }
}

/// Disk-backed cards. Access is serialized because Core Bluetooth uses its own queue.
/// Remote photo URLs are never fetched: only validated, content-addressed local files.
final class LocalCardStore: @unchecked Sendable {
    static let shared = LocalCardStore()
    private let lock = NSRecursiveLock()
    private let directory: URL
    private let defaults: UserDefaults
    private let secureStore: SecureStoring
    private let keyName = "shum.local-card.signing-key.v1"
    private var own: LocalCardManifest?
    private var peers: [String: LocalCardManifest] = [:]

    init(directory: URL? = nil, defaults: UserDefaults = .standard, secureStore: SecureStoring = KeychainStore.shared) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalCards-v1", isDirectory: true)
        self.defaults = defaults
        self.secureStore = secureStore
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("own.json")),
           let value = try? JSONDecoder().decode(LocalCardManifest.self, from: data),
           (try? value.validate()) != nil { own = value }
        if let data = try? Data(contentsOf: self.directory.appendingPathComponent("peers.json")), data.count <= 2 * 1024 * 1024,
           let values = try? JSONDecoder().decode([String: LocalCardManifest].self, from: data) {
            peers = values.filter { $0.key == $0.value.body.id.uuidString.lowercased() && (try? $0.value.validate()) != nil }
        }
    }

    var ownManifest: LocalCardManifest? { lock.withLock { own } }
    func photoURL(_ hash: String?) -> URL? {
        lock.withLock {
            guard let hash, LocalCardPhoto.validHash(hash) else { return nil }
            let url = directory.appendingPathComponent(hash + ".jpg")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
    func photo(_ hash: String?) -> Data? {
        lock.withLock {
            guard let hash, let url = photoURL(hash), let data = try? Data(contentsOf: url),
                  LocalCardPhoto.hash(data) == hash, LocalCardPhoto.validate(data) else { return nil }
            return data
        }
    }
    func snapshot(_ manifest: LocalCardManifest) -> ShumProfileResponse {
        let body = manifest.body
        return ShumProfileResponse(shumId: body.id, name: body.name, username: body.username.isEmpty ? nil : body.username,
            bio: body.bio, photoUrl: photoURL(body.photoHash)?.absoluteString)
    }
    func profile(_ id: UUID) throws -> ShumProfileResponse {
        try lock.withLock {
            guard let value = peers[id.uuidString.lowercased()] else { throw LocalCardError.unavailable }
            return snapshot(value)
        }
    }
    @discardableResult
    func saveOwn(name: String, username: String? = nil, bio: String?, photo: Data?) throws -> LocalCardManifest {
        try lock.withLock {
            let normalizedUsername = username.flatMap(LocalCardManifest.username)
            if username != nil && normalizedUsername == nil { throw LocalCardError.invalidProfile }
            let key: Curve25519.Signing.PrivateKey
            if let bytes = try secureStore.data(for: keyName) {
                key = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
            } else {
                key = Curve25519.Signing.PrivateKey()
                try secureStore.set(key.rawRepresentation, for: keyName)
            }
            let publicKey = key.publicKey.rawRepresentation
            let body = LocalCardBody(version: username == nil ? 2 : 1, id: LocalCardManifest.identity(for: publicKey),
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), username: normalizedUsername ?? "",
                bio: bio.flatMap { $0.isEmpty ? nil : String($0.prefix(36)) },
                photoHash: photo.map(LocalCardPhoto.hash), photoBytes: photo?.count ?? 0)
            let result = LocalCardManifest(body: body, publicKey: publicKey,
                signature: try key.signature(for: LocalCardManifest.encodedBody(body)))
            try result.validate()
            if let photo { try cachePhoto(photo, hash: body.photoHash!) }
            try write(result, name: "own.json")
            own = result
            pruneUnreferencedPhotos()
            return result
        }
    }
    func receive(_ manifest: LocalCardManifest) throws {
        try lock.withLock {
            try manifest.validate()
            let id = manifest.body.id.uuidString.lowercased()
            guard !isBlocked(manifest.body.id) else { throw LocalCardError.unavailable }
            guard peers[id] != manifest else { return }
            // Keep saved identities; bound the ordinary discovery cache.
            if peers.count >= 500, peers[id] == nil {
                let saved = Set(defaults.stringArray(forKey: "savedPeopleProfileIDs")?.map { $0.lowercased() } ?? [])
                if let stale = peers.keys.first(where: { !saved.contains($0) }) { peers.removeValue(forKey: stale) }
                else { throw LocalCardError.unavailable }
            }
            peers[id] = manifest
            try write(peers, name: "peers.json")
            pruneUnreferencedPhotos()
        }
    }
    func cachePhoto(_ data: Data, hash: String) throws {
        try lock.withLock {
            guard LocalCardPhoto.validHash(hash), LocalCardPhoto.hash(data) == hash,
                  LocalCardPhoto.validate(data) else { throw LocalCardError.invalidPhoto }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(hash + ".jpg"), options: .atomic)
        }
    }
    func isBlocked(_ id: UUID) -> Bool {
        Set(defaults.stringArray(forKey: "shum.blocked-profile-ids") ?? []).contains(id.uuidString.lowercased())
    }
    func reset() throws {
        try lock.withLock {
            try secureStore.remove(keyName)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            own = nil
            peers.removeAll()
        }
    }
    private func write<T: Encodable>(_ value: T, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: directory.appendingPathComponent(name), options: .atomic)
    }
    private func pruneUnreferencedPhotos() {
        var protected = Set(peers.values.compactMap { $0.body.photoHash })
        if let hash = own?.body.photoHash { protected.insert(hash) }
        // Allow a small reserve for in-flight exchanges and older saved snapshots.
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let unused = files.filter {
            $0.pathExtension == "jpg" && LocalCardPhoto.validHash($0.deletingPathExtension().lastPathComponent)
                && !protected.contains($0.deletingPathExtension().lastPathComponent)
        }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in unused.dropFirst(50) { try? FileManager.default.removeItem(at: file) }
    }
}
