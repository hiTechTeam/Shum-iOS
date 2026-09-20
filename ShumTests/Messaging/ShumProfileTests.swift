#if os(iOS)
import BitFoundation
import Foundation
import Testing
import UIKit
@preconcurrency @testable import Shum

@Suite("Shum profile exchange", .serialized)
@MainActor
struct ShumProfileTests {
    private let alice = PeerID(str: "1111111111111111")
    private let bob = PeerID(str: "2222222222222222")

    private func photo() throws -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 360, height: 360), format: format).image { ctx in
            for y in stride(from: 0, to: 360, by: 8) {
                for x in stride(from: 0, to: 360, by: 8) {
                    UIColor(red: CGFloat((x * 7 + y * 3) % 255) / 255,
                            green: CGFloat((x * 3 + y * 11) % 255) / 255,
                            blue: CGFloat((x * 13 + y * 7) % 255) / 255, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 8, height: 8))
                }
            }
        }
        return try ShumAvatarCodec.prepare(#require(image.pngData()))
    }
    @MainActor private final class Network {
        var clock = Date(timeIntervalSince1970: 1000)
        var online = true
        var nodes: [PeerID: ShumProfiles] = [:]
        var queue: [(PeerID, PeerID, Data)] = []
        var sent: [(PeerID, PeerID, ShumProfilePacket)] = []
        func add(_ peer: PeerID, name: String, store: ShumProfileStore = ShumProfileStore()) -> ShumProfiles {
            let model = ShumProfiles(name: name, store: store, now: { [weak self] in self?.clock ?? .distantPast },
                connected: { [weak self] peer in self?.online == true && self?.nodes[peer] != nil },
                send: { [weak self] data, to in self?.queue.append((peer, to, data)) })
            nodes[peer] = model
            return model
        }
        func drain(drop: (ShumProfilePacket) -> Bool = { _ in false }) throws {
            var count = 0
            while !queue.isEmpty && count < 2000 {
                count += 1; clock.addTimeInterval(0.08)
                let (from, to, data) = queue.removeFirst()
                #expect(data.count <= ShumProfilePacket.maxWireBytes)
                let packet = try JSONDecoder().decode(ShumProfilePacket.self, from: data)
                sent.append((from, to, packet))
                if !drop(packet) { nodes[to]?.receive(data, from: from) }
            }
            #expect(queue.isEmpty)
        }
    }

    @Test("Chunked photos and profiles exchange, cache and photo deletion propagate")
    func exchangeAndCache() throws {
        let wire = Network()
        let a = wire.add(alice, name: "Аня"), b = wire.add(bob, name: "Борис")
        let avatar = try photo()
        #expect(avatar.count > ShumProfilePacket.chunkSize)
        try a.save(.init(name: "Аня", bio: "Привет 👋", avatar: avatar))
        a.updatePeers([bob]); b.updatePeers([alice]); a.tick(); b.tick()
        try wire.drain()
        #expect(b.remote[alice] == a.own)
        #expect(a.remote[bob] == b.own)
        #expect(b.loading.isEmpty && b.failed.isEmpty)
        let chunks = wire.sent.filter { $0.2.kind == .chunk }.count
        b.refresh(alice); try wire.drain()
        #expect(wire.sent.filter { $0.2.kind == .chunk }.count == chunks)
        try a.save(.init(name: "Аня", bio: "Новое описание", avatar: nil)); try wire.drain()
        #expect(b.remote[alice]?.bio == "Новое описание")
        #expect(b.remote[alice]?.avatar == nil)
    }

    @Test("Lost avatar chunk retries same offset without duplicating bytes")
    func retryChunk() throws {
        let wire = Network(); let a = wire.add(alice, name: "Аня"), b = wire.add(bob, name: "Борис")
        try a.save(.init(name: "Аня", avatar: photo()))
        b.updatePeers([alice]); b.tick()
        var dropped = false
        try wire.drain { packet in
            if packet.kind == .chunk && !dropped { dropped = true; return true }; return false
        }
        #expect(b.loading.contains(alice))
        wire.clock.addTimeInterval(9); b.tick(); try wire.drain()
        #expect(b.remote[alice]?.avatar == a.own.avatar)
        let requests = wire.sent.filter { $0.2.kind == .chunkRequest && $0.2.offset == 0 }
        #expect(requests.count == 2)
        #expect(Set(requests.map { $0.2.request }).count == 1)
    }

    @Test("Unsolicited, oversized and corrupt profile payloads never become avatars")
    func rejectedPackets() throws {
        let wire = Network(); let a = wire.add(alice, name: "Аня"), b = wire.add(bob, name: "Борис")
        let profile = ShumProfile(name: "Аня", avatar: try photo())
        let unsolicited = ShumProfilePacket(kind: .manifest, request: "wrong", manifest: .init(profile))
        b.receive(try JSONEncoder().encode(unsolicited), from: alice)
        #expect(b.remote.isEmpty)
        b.receive(Data(repeating: 0, count: 10000), from: alice)
        #expect(b.remote.isEmpty)
        try a.save(profile); b.updatePeers([alice]); b.tick()
        // Deliver query, then valid descriptor; replace the final bytes with corruption.
        var steps = 0
        while !wire.queue.isEmpty && steps < 100 {
            steps += 1; wire.clock.addTimeInterval(0.1)
            let (from, to, data) = wire.queue.removeFirst()
            var packet = try JSONDecoder().decode(ShumProfilePacket.self, from: data)
            if packet.kind == .chunk, let chunk = packet.data { packet.data = Data(repeating: 0, count: chunk.count) }
            wire.nodes[to]?.receive(try JSONEncoder().encode(packet), from: from)
        }
        #expect(b.remote[alice]?.avatar == nil)
        #expect(b.failed.contains(alice))
    }

    @Test("Disconnect cancels requests and stale responses; reconnect can finish")
    func reconnect() throws {
        let wire = Network(); let a = wire.add(alice, name: "Аня"), b = wire.add(bob, name: "Борис")
        try a.save(.init(name: "Аня", avatar: photo()))
        b.updatePeers([alice]); b.tick()
        let old = try #require(wire.queue.first)
        b.updatePeers([])
        try wire.drain()
        #expect(b.remote.isEmpty)
        b.updatePeers([alice]); b.tick(); try wire.drain()
        #expect(b.remote[alice]?.avatar == a.own.avatar)
        #expect(!old.2.isEmpty)
    }

    @Test("Own profile and bounded content-addressed avatar cache survive restart")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShumProfileStore(directory: directory)
        let profile = ShumProfile(name: "Аня", bio: "Сохранено", avatar: try photo())
        try store.saveOwn(profile)
        #expect(ShumProfileStore(directory: directory).loadOwn() == profile)
        let data = try #require(profile.avatar), hash = ShumProfile.digest(data)
        store.cache(data, hash: hash)
        #expect(ShumProfileStore(directory: directory).avatar(hash) == data)
        #expect(store.avatar("../../own") == nil)
        #expect(!ShumProfile(name: "Аня", bio: String(repeating: "x", count: 73)).valid)
        #expect(!ShumProfile.validAvatar(Data(repeating: 0, count: 400)))
        #expect(ShumProfile(name: "Аня", bio: String(repeating: "я", count: 72)).valid)
        var legacy = profile
        legacy.bio = String(repeating: "я", count: 160)
        try store.saveOwn(legacy)
        let migrated = try #require(store.loadOwn())
        #expect(migrated.bio == String(repeating: "я", count: 72))
        #expect(migrated.name == profile.name && migrated.avatar == profile.avatar)
    }
    @Test("Photo requests survive suspension without expiring or polling in background")
    func suspendedPhoto() throws {
        let wire = Network(); let a = wire.add(alice, name: "Аня"), b = wire.add(bob, name: "Борис")
        try a.save(.init(name: "Аня", avatar: photo()))
        b.updatePeers([alice]); b.tick()
        var dropped = false
        try wire.drain { packet in
            if packet.kind == .chunk && !dropped { dropped = true; return true }; return false
        }
        let sent = wire.sent.count
        b.setAppActive(false)
        wire.clock.addTimeInterval(3600); b.tick(); try wire.drain()
        #expect(wire.sent.count == sent)
        #expect(b.failed.isEmpty)
        b.setAppActive(true); b.tick(); try wire.drain()
        #expect(b.remote[alice]?.avatar == a.own.avatar)
        #expect(b.failed.isEmpty && b.loading.isEmpty)
    }

}
#endif
