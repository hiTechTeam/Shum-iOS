import BitFoundation
import Combine
import CryptoKit
import Foundation
import ImageIO

protocol ShumProfileTransporting: AnyObject {
    func sendShumProfile(_ data: Data, to peer: PeerID)
}
extension BLEService: ShumProfileTransporting {}

struct ShumProfile: Codable, Equatable {
    var name: String
    var bio: String = ""
    var avatar: Data?
    static let maxBioCharacters = 72
    static let maxAvatarBytes = 40 * 1024

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func validAvatar(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxAvatarBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 360, height <= 360 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
    var valid: Bool {
        InputValidator.validateNickname(name) == name && name.utf8.count <= 64 && bio.count <= Self.maxBioCharacters && bio.utf8.count <= 640 &&
        !bio.unicodeScalars.contains { CharacterSet.controlCharacters.subtracting(.newlines).contains($0) } &&
        (avatar.map(Self.validAvatar) ?? true)
    }
}

struct ShumProfileManifest: Codable, Equatable {
    let name: String
    let bio: String
    let avatarHash: String?
    let avatarBytes: Int
    var revision: String { ShumProfile.digest(Data((name + "\0" + bio + "\0" + (avatarHash ?? "")).utf8)) }
    init(_ profile: ShumProfile) {
        name = profile.name; bio = profile.bio
        avatarHash = profile.avatar.map(ShumProfile.digest); avatarBytes = profile.avatar?.count ?? 0
    }
    var valid: Bool {
        ShumProfile(name: name, bio: bio).valid && avatarBytes >= 0 && avatarBytes <= ShumProfile.maxAvatarBytes &&
        (avatarHash.map { Self.validHash($0) && avatarBytes > 0 } ?? (avatarBytes == 0))
    }
    static func validHash(_ hash: String) -> Bool { hash.count == 64 && hash.allSatisfy { "0123456789abcdef".contains($0) } }
}

struct ShumProfilePacket: Codable {
    enum Kind: String, Codable { case query, manifest, chunkRequest, chunk, changed }
    var version = 1
    let kind: Kind
    var request: String = ""
    var manifest: ShumProfileManifest?
    var hash: String?
    var offset: Int?
    var data: Data?
    static let chunkSize = 3072
    static let maxWireBytes = 6144
}

/// Own profile is persistent; remote identity-to-profile bindings are accepted from
/// an encrypted BLE session or a cryptographically authenticated Nostr lookup.
/// Only content-addressed images survive a restart.
final class ShumProfileStore {
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }
    static func live() -> ShumProfileStore {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return ShumProfileStore(directory: root.appendingPathComponent("ShumProfiles", isDirectory: true))
    }
    func loadOwn() -> ShumProfile? {
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("own.json")),
              data.count <= 60 * 1024, var profile = try? JSONDecoder().decode(ShumProfile.self, from: data) else { return nil }
        profile.bio = String(profile.bio.prefix(ShumProfile.maxBioCharacters))
        guard profile.valid else { return nil }
        return profile
    }
    func saveOwn(_ profile: ShumProfile) throws {
        guard let directory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(profile).write(to: directory.appendingPathComponent("own.json"), options: .atomic)
    }
    func avatar(_ hash: String) -> Data? {
        guard ShumProfileManifest.validHash(hash), let directory,
              let data = try? Data(contentsOf: directory.appendingPathComponent(hash + ".jpg")),
              ShumProfile.digest(data) == hash, ShumProfile.validAvatar(data) else { return nil }
        return data
    }
    func cache(_ data: Data, hash: String) {
        guard ShumProfileManifest.validHash(hash), ShumProfile.digest(data) == hash,
              ShumProfile.validAvatar(data), let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(hash + ".jpg"), options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let images = files.filter { $0.pathExtension == "jpg" }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for file in images.dropFirst(60) { try? FileManager.default.removeItem(at: file) }
    }
}

@MainActor
final class ShumProfiles: ObservableObject {
    @Published private(set) var own: ShumProfile
    @Published private(set) var remote: [PeerID: ShumProfile] = [:]
    @Published private(set) var loading: Set<PeerID> = []
    @Published private(set) var failed: Set<PeerID> = []
    private struct Pending {
        let request: String
        var manifest: ShumProfileManifest?
        var bytes = Data()
        var lastSent = Date.distantPast
        var attempts = 0
        var started: Date
    }
    private let store: ShumProfileStore
    private let send: (Data, PeerID) -> Void
    private let connected: (PeerID) -> Bool
    private let now: () -> Date
    private var peers: Set<PeerID> = []
    private var pending: [PeerID: Pending] = [:]
    private var checked: [PeerID: Date] = [:]
    private var packetRate: [PeerID: (Date, Int)] = [:]
    private var hints: [PeerID: Date] = [:]
    private var appActive = true
    private var retired = false
    static let retryInterval: TimeInterval = 8

    init(name: String, store: ShumProfileStore = ShumProfileStore(),
         now: @escaping () -> Date = Date.init, connected: @escaping (PeerID) -> Bool,
         send: @escaping (Data, PeerID) -> Void) {
        self.store = store; self.now = now; self.connected = connected; self.send = send
        own = store.loadOwn() ?? ShumProfile(name: name)
    }
    func retire() {
        retired = true; appActive = false
        pending.removeAll(); peers.removeAll(); remote.removeAll(); loading.removeAll(); failed.removeAll()
        own = ShumProfile(name: "")
    }
    func save(_ profile: ShumProfile) throws {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        guard profile.valid else { throw CocoaError(.validationMissingMandatoryProperty) }
        try store.saveOwn(profile)
        own = profile
        for peer in peers where connected(peer) { emit(.init(kind: .changed), to: peer) }
    }
    func updatePeers(_ ids: Set<PeerID>) {
        let gone = peers.subtracting(ids)
        for peer in gone { pending[peer] = nil; checked[peer] = nil; packetRate[peer] = nil; hints[peer] = nil; loading.remove(peer); failed.remove(peer) }
        peers = Set(ids.sorted { $0.id < $1.id }.prefix(100))
        if remote.count > 100 { remote = remote.filter { peers.contains($0.key) } }
    }
    func refresh(_ peer: PeerID) {
        checked[peer] = nil; pending[peer] = nil; failed.remove(peer)
        tick()
    }
    func acceptResolved(_ profile: ShumProfile, for peer: PeerID) {
        guard !retired, profile.valid else { return }
        remote[peer] = profile
        if let avatar = profile.avatar {
            store.cache(avatar, hash: ShumProfile.digest(avatar))
        }
        loading.remove(peer)
        failed.remove(peer)
    }
    func setAppActive(_ active: Bool) {
        guard appActive != active else { return }
        appActive = active
        if active {
            for peer in Array(pending.keys) {
                pending[peer]?.started = now()
                pending[peer]?.lastSent = .distantPast
                pending[peer]?.attempts = 0
            }
        }
    }
    func tick() {
        guard appActive else { return }
        for peer in peers.sorted(by: { $0.id < $1.id }) where connected(peer) {
            if let item = pending[peer] {
                if now().timeIntervalSince(item.started) > 180 || (item.attempts >= 4 && now().timeIntervalSince(item.lastSent) >= Self.retryInterval) {
                    pending[peer] = nil; checked[peer] = now(); loading.remove(peer); failed.insert(peer)
                } else if now().timeIntervalSince(item.lastSent) >= Self.retryInterval { requestNext(peer) }
            } else if pending.count < 4 && now().timeIntervalSince(checked[peer] ?? .distantPast) >= 30 {
                pending[peer] = Pending(request: UUID().uuidString, started: now())
                requestNext(peer)
            }
        }
    }
    private func emit(_ packet: ShumProfilePacket, to peer: PeerID) {
        guard !retired else { return }
        guard connected(peer), let data = try? JSONEncoder().encode(packet), data.count <= ShumProfilePacket.maxWireBytes else { return }
        send(data, peer)
    }
    private func requestNext(_ peer: PeerID) {
        guard var item = pending[peer] else { return }
        item.lastSent = now(); item.attempts += 1; pending[peer] = item
        if let manifest = item.manifest {
            emit(.init(kind: .chunkRequest, request: item.request, hash: manifest.avatarHash, offset: item.bytes.count), to: peer)
        } else { emit(.init(kind: .query, request: item.request), to: peer) }
    }
    func receive(_ data: Data, from peer: PeerID) {
        guard !retired else { return }
        guard connected(peer), data.count <= ShumProfilePacket.maxWireBytes,
              let packet = try? JSONDecoder().decode(ShumProfilePacket.self, from: data), packet.version == 1,
              packet.request.utf8.count <= 64 else { return }
        if !peers.contains(peer) { guard peers.count < 100 else { return }; peers.insert(peer) }
        let rate = packetRate[peer] ?? (.distantPast, 0)
        if now().timeIntervalSince(rate.0) < 1 {
            guard rate.1 < 20 else { return }; packetRate[peer] = (rate.0, rate.1 + 1)
        } else { packetRate[peer] = (now(), 1) }
        switch packet.kind {
        case .query:
            guard !packet.request.isEmpty else { return }
            emit(.init(kind: .manifest, request: packet.request, manifest: ShumProfileManifest(own)), to: peer)
        case .changed:
            guard now().timeIntervalSince(hints[peer] ?? .distantPast) >= 2 else { return }
            hints[peer] = now(); refresh(peer)
        case .manifest:
            guard var item = pending[peer], item.request == packet.request,
                  item.manifest == nil, let manifest = packet.manifest, manifest.valid else { return }
            failed.remove(peer)
            let previous = remote[peer]?.avatar
            let cached = manifest.avatarHash.flatMap { hash in
                previous.flatMap { ShumProfile.digest($0) == hash ? $0 : nil } ?? store.avatar(hash)
            }
            remote[peer] = ShumProfile(name: manifest.name, bio: manifest.bio, avatar: cached)
            if manifest.avatarHash == nil || cached != nil {
                finish(peer)
            } else {
                item.manifest = manifest; item.attempts = 0; item.bytes = Data(); pending[peer] = item
                loading.insert(peer); requestNext(peer)
            }
        case .chunkRequest:
            guard !packet.request.isEmpty, let avatar = own.avatar, let hash = packet.hash,
                  hash == ShumProfile.digest(avatar), let offset = packet.offset,
                  offset >= 0, offset < avatar.count, offset % ShumProfilePacket.chunkSize == 0 else { return }
            let end = min(avatar.count, offset + ShumProfilePacket.chunkSize)
            emit(.init(kind: .chunk, request: packet.request, hash: hash, offset: offset, data: avatar.subdata(in: offset..<end)), to: peer)
        case .chunk:
            guard var item = pending[peer], item.request == packet.request,
                  let manifest = item.manifest, packet.hash == manifest.avatarHash,
                  packet.offset == item.bytes.count, let bytes = packet.data,
                  bytes.count == min(ShumProfilePacket.chunkSize, manifest.avatarBytes - item.bytes.count), !bytes.isEmpty else { return }
            item.bytes.append(bytes); item.attempts = 0; pending[peer] = item
            if item.bytes.count == manifest.avatarBytes {
                guard ShumProfile.digest(item.bytes) == manifest.avatarHash, ShumProfile.validAvatar(item.bytes) else {
                    pending[peer] = nil; checked[peer] = now(); loading.remove(peer); failed.insert(peer); return
                }
                remote[peer] = ShumProfile(name: manifest.name, bio: manifest.bio, avatar: item.bytes)
                store.cache(item.bytes, hash: manifest.avatarHash!)
                finish(peer)
            } else { requestNext(peer) }
        }
    }
    private func finish(_ peer: PeerID) {
        pending[peer] = nil; checked[peer] = now(); loading.remove(peer); failed.remove(peer)
    }
    #if DEBUG && targetEnvironment(simulator)
    func seedPreview(_ profile: ShumProfile, for peer: PeerID) { remote[peer] = profile }
    #endif

}
