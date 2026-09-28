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
    var avatarSeed: UInt64?
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

    @MainActor
    func rendered() -> ShumProfile {
        guard let avatarSeed else { return self }
        var result = self
        result.avatar = ShumPixelAvatarGenerator.data(seed: avatarSeed)
        return result
    }
}

struct ShumProfileManifest: Codable, Equatable {
    let name: String
    let bio: String
    let avatarHash: String?
    let avatarBytes: Int
    let avatarSeed: UInt64?
    let avatarVersion: Int?
    var revision: String { ShumProfile.digest(Data((name + "\0" + bio + "\0" + (avatarHash ?? "") + "\0" + (avatarSeed.map(String.init) ?? "") + "\0" + (avatarVersion.map(String.init) ?? "")).utf8)) }
    init(_ profile: ShumProfile) {
        name = profile.name; bio = profile.bio
        avatarSeed = profile.avatarSeed
        avatarVersion = profile.avatarSeed.map { _ in ShumPixelAvatarGenerator.version }
        avatarHash = avatarSeed == nil ? profile.avatar.map(ShumProfile.digest) : nil
        avatarBytes = avatarSeed == nil ? profile.avatar?.count ?? 0 : 0
    }
    var valid: Bool {
        ShumProfile(name: name, bio: bio).valid && avatarBytes >= 0 && avatarBytes <= ShumProfile.maxAvatarBytes &&
        (avatarSeed == nil
            ? avatarVersion == nil && (avatarHash.map { Self.validHash($0) && avatarBytes > 0 } ?? (avatarBytes == 0))
            : avatarVersion == ShumPixelAvatarGenerator.version && avatarHash == nil && avatarBytes == 0)
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

/// Own profile is persistent; remote profiles arrive through an encrypted BLE
/// session or an authenticated Nostr lookup. Avatar pixels are regenerated locally.
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
        var stored = profile
        stored.avatar = nil
        try JSONEncoder().encode(stored).write(to: directory.appendingPathComponent("own.json"), options: .atomic)
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
        own = (store.loadOwn() ?? ShumProfile(name: name)).rendered()
    }
    func retire() {
        retired = true; appActive = false
        pending.removeAll(); peers.removeAll(); remote.removeAll(); loading.removeAll(); failed.removeAll()
        own = ShumProfile(name: "")
    }
    func save(_ profile: ShumProfile) throws {
        guard !retired else { throw ShumFailure.unavailableIdentity }
        guard profile.valid else { throw CocoaError(.validationMissingMandatoryProperty) }
        let displayed = profile.rendered()
        try store.saveOwn(displayed)
        own = displayed
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
        remote[peer] = profile.rendered()
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
        emit(.init(kind: .query, request: item.request), to: peer)
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
            guard let item = pending[peer], item.request == packet.request,
                  let manifest = packet.manifest, manifest.valid else { return }
            failed.remove(peer)
            if let seed = manifest.avatarSeed {
                remote[peer] = ShumProfile(name: manifest.name, bio: manifest.bio,
                    avatarSeed: seed).rendered()
                finish(peer)
                return
            }
            remote[peer] = ShumProfile(name: manifest.name, bio: manifest.bio)
            finish(peer)
        case .chunkRequest:
            return
        case .chunk:
            return
        }
    }
    private func finish(_ peer: PeerID) {
        pending[peer] = nil; checked[peer] = now(); loading.remove(peer); failed.remove(peer)
    }
    #if DEBUG && targetEnvironment(simulator)
    func seedPreview(_ profile: ShumProfile, for peer: PeerID) { remote[peer] = profile }
    #endif

}
