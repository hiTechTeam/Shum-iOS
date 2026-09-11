import Foundation

/// A direct, bidirectional GATT exchange. No relay, HTTP or foreground-only timer.
/// Frames fit the negotiated ATT size, including the minimum 20-byte value size.
final class BLECardExchange {
    enum Kind: UInt8 { case manifest = 1, photo = 2, photoRequest = 3, done = 4 }
    static let headerBytes = 9
    private struct Outgoing { let kind: Kind; let token: UInt32; let data: Data; var offset = 0 }
    private struct Incoming { let kind: Kind; let token: UInt32; let total: Int; var data = Data() }
    private var outgoing: [Outgoing] = []
    private var incoming: Incoming?
    private var token: UInt32 = 0
    private let own: LocalCardManifest
    private let ownPhoto: Data?
    private let expectedPeer: UUID?
    private let store: LocalCardStore
    private let publish: (LocalCardManifest) -> Void
    private(set) var peer: LocalCardManifest?
    private(set) var touchedAt = Date()
    private var receivedProfile = false
    private var sentProfile = false
    private var servedPhoto = false
    var hasOutgoing: Bool { !outgoing.isEmpty }
    var complete: Bool { receivedProfile && sentProfile && outgoing.isEmpty }

    init(own: LocalCardManifest, expectedPeer: UUID?, store: LocalCardStore = .shared,
         publish: @escaping (LocalCardManifest) -> Void) throws {
        self.own = own
        self.ownPhoto = store.photo(own.body.photoHash)
        self.expectedPeer = expectedPeer
        self.store = store
        self.publish = publish
        try enqueue(.manifest, data: JSONEncoder().encode(own))
    }

    private func enqueue(_ kind: Kind, data: Data) throws {
        guard !data.isEmpty, data.count <= Self.limit(kind), outgoing.count < 8 else { throw LocalCardError.invalidPacket }
        token &+= 1
        outgoing.append(Outgoing(kind: kind, token: token, data: data))
    }

    func nextFrame(maximumBytes: Int) -> Data? {
        guard var message = outgoing.first, maximumBytes > Self.headerBytes else { return nil }
        let count = min(maximumBytes - Self.headerBytes, message.data.count - message.offset)
        var frame = Data([message.kind.rawValue])
        frame.append(contentsOf: [UInt8(truncatingIfNeeded: message.token >> 24), UInt8(truncatingIfNeeded: message.token >> 16), UInt8(truncatingIfNeeded: message.token >> 8), UInt8(truncatingIfNeeded: message.token)])
        for number in [message.data.count, message.offset] {
            frame.append(contentsOf: [UInt8(truncatingIfNeeded: number >> 8), UInt8(truncatingIfNeeded: number)])
        }
        frame.append(message.data.subdata(in: message.offset..<(message.offset + count)))
        message.offset += count
        if message.offset == message.data.count { outgoing.removeFirst() }
        else { outgoing[0] = message }
        return frame
    }

    func receive(_ frame: Data) throws {
        guard frame.count > Self.headerBytes, frame.count <= 512,
              let kind = Kind(rawValue: frame[0]) else { throw LocalCardError.invalidPacket }
        let token = frame[1..<5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let total = Int(frame[5]) * 256 + Int(frame[6])
        let offset = Int(frame[7]) * 256 + Int(frame[8])
        let payload = frame.dropFirst(Self.headerBytes)
        guard total > 0, total <= Self.limit(kind), offset + payload.count <= total else { throw LocalCardError.invalidPacket }
        if offset == 0 {
            guard incoming == nil else { throw LocalCardError.invalidPacket }
            incoming = Incoming(kind: kind, token: token, total: total)
        }
        guard var message = incoming, message.kind == kind, message.token == token,
              message.total == total, message.data.count == offset else { throw LocalCardError.invalidPacket }
        touchedAt = Date()
        message.data.append(contentsOf: payload)
        incoming = message
        if message.data.count == total {
            incoming = nil
            try accept(kind, data: message.data)
        }
    }

    private static func limit(_ kind: Kind) -> Int {
        switch kind {
        case .manifest: 2048
        case .photo: LocalCardPhoto.maximumBytes
        case .photoRequest: 64
        case .done: 1
        }
    }
    private func accept(_ kind: Kind, data: Data) throws {
        switch kind {
        case .manifest:
            guard peer == nil else { throw LocalCardError.invalidPacket }
            let manifest = try JSONDecoder().decode(LocalCardManifest.self, from: data)
            try manifest.validate()
            guard manifest.body.id != own.body.id,
                  expectedPeer == nil || manifest.body.id == expectedPeer else { throw LocalCardError.invalidProfile }
            try store.receive(manifest)
            peer = manifest
            publish(manifest)
            if let hash = manifest.body.photoHash, store.photo(hash) == nil {
                try enqueue(.photoRequest, data: Data(hash.utf8))
            } else { try finishReceiving() }
        case .photoRequest:
            guard peer != nil, !servedPhoto, let photo = ownPhoto,
                  String(data: data, encoding: .utf8) == own.body.photoHash else { throw LocalCardError.invalidPacket }
            servedPhoto = true
            try enqueue(.photo, data: photo)
        case .photo:
            guard !receivedProfile, let peer, let hash = peer.body.photoHash,
                  data.count == peer.body.photoBytes, !store.isBlocked(peer.body.id) else { throw LocalCardError.invalidPacket }
            try store.cachePhoto(data, hash: hash)
            publish(peer)
            try finishReceiving()
        case .done:
            guard peer != nil, data == Data([1]) else { throw LocalCardError.invalidPacket }
            sentProfile = true
        }
    }
    private func finishReceiving() throws {
        receivedProfile = true
        try enqueue(.done, data: Data([1]))
    }
}
