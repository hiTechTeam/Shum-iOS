#if os(iOS)
import BitFoundation
import Foundation
import Testing
@preconcurrency @testable import Shum

@Suite("Shum profile exchange", .serialized)
@MainActor
struct ShumProfileTests {
    private let alice = PeerID(str: "1111111111111111")
    private let bob = PeerID(str: "2222222222222222")

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

    @Test("Seeded avatars cross Bluetooth as a descriptor without image chunks")
    func seededAvatarExchange() throws {
        let wire = Network()
        let a = wire.add(alice, name: "Аня")
        let b = wire.add(bob, name: "Борис")
        let seed: UInt64 = 0x726F626F74536875
        try a.save(.init(name: "Аня", bio: "Привет", avatarSeed: seed))
        a.updatePeers([bob]); b.updatePeers([alice]); a.tick(); b.tick()
        try wire.drain()

        #expect(b.remote[alice]?.avatarSeed == seed)
        #expect(b.remote[alice]?.avatar == a.own.avatar)
        #expect(b.remote[alice]?.avatar != nil)
        #expect(wire.sent.allSatisfy { $0.2.kind != .chunk && $0.2.data == nil })
        let manifest = try #require(wire.sent.first { $0.2.kind == .manifest && $0.2.manifest?.avatarSeed == seed }?.2.manifest)
        #expect(manifest.avatarVersion == ShumPixelAvatarGenerator.version)
        #expect(manifest.avatarBytes == 0 && manifest.avatarHash == nil)
    }

    @Test("Changed seed propagates without transferring image data")
    func changedSeed() throws {
        let wire = Network()
        let a = wire.add(alice, name: "Аня"), b = wire.add(bob, name: "Борис")
        try a.save(.init(name: "Аня", avatarSeed: 10))
        a.updatePeers([bob]); b.updatePeers([alice]); a.tick(); b.tick()
        try wire.drain()
        let first = try #require(b.remote[alice]?.avatar)
        try a.save(.init(name: "Аня", avatarSeed: 11))
        try wire.drain()
        b.refresh(alice); try wire.drain()
        #expect(b.remote[alice]?.avatarSeed == 11)
        #expect(b.remote[alice]?.avatar != first)
        #expect(wire.sent.allSatisfy { $0.2.kind != .chunk && $0.2.data == nil })
    }

    @Test("Unexpected and unsupported profile descriptors are ignored")
    func rejectedPackets() throws {
        let wire = Network()
        let a = wire.add(alice, name: "Аня"), b = wire.add(bob, name: "Борис")
        let profile = ShumProfile(name: "Аня", avatarSeed: 42)
        let unsolicited = ShumProfilePacket(kind: .manifest, request: "wrong", manifest: .init(profile))
        b.receive(try JSONEncoder().encode(unsolicited), from: alice)
        b.receive(Data(repeating: 0, count: 10_000), from: alice)
        #expect(b.remote.isEmpty)
        let valid = try JSONEncoder().encode(ShumProfileManifest(profile))
        let unsupported = Data(String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(of: "\"avatarVersion\":1", with: "\"avatarVersion\":99").utf8)
        let descriptor = try JSONDecoder().decode(ShumProfileManifest.self, from: unsupported)
        #expect(!descriptor.valid)
        #expect(ShumProfileManifest(profile).valid)
    }

    @Test("Disconnect rejects stale reply, then reconnect resolves the seed")
    func reconnect() throws {
        let wire = Network()
        let a = wire.add(alice, name: "Аня"), b = wire.add(bob, name: "Борис")
        try a.save(.init(name: "Аня", avatarSeed: 77))
        b.updatePeers([alice]); b.tick()
        let old = try #require(wire.queue.first)
        b.updatePeers([])
        try wire.drain()
        #expect(b.remote.isEmpty)
        b.updatePeers([alice]); b.tick(); try wire.drain()
        #expect(b.remote[alice]?.avatarSeed == 77)
        #expect(b.remote[alice]?.avatar == a.own.avatar)
        #expect(!old.2.isEmpty)
    }

    @Test("Only the seed is persisted and the portrait regenerates on restart")
    func persistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ShumProfileStore(directory: directory)
        let profile = ShumProfile(name: "Аня", bio: "Сохранено", avatarSeed: 123).rendered()
        try store.saveOwn(profile)
        let disk = try Data(contentsOf: directory.appendingPathComponent("own.json"))
        #expect(disk.count < 512)
        #expect(store.loadOwn()?.avatarSeed == 123)
        #expect(store.loadOwn()?.avatar == nil)
        let restarted = ShumProfiles(name: "Аня", store: store,
            connected: { _ in false }, send: { _, _ in })
        #expect(restarted.own.avatar == profile.avatar)
        #expect((try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil)).allSatisfy { $0.pathExtension != "jpg" })
    }

    @Test("Suspended profile requests resume without image chunks")
    func suspendedProfile() throws {
        let wire = Network()
        let a = wire.add(alice, name: "Аня"), b = wire.add(bob, name: "Борис")
        try a.save(.init(name: "Аня", avatarSeed: 246))
        b.updatePeers([alice]); b.tick()
        let sent = wire.queue.count
        b.setAppActive(false)
        wire.clock.addTimeInterval(3600); b.tick()
        #expect(wire.queue.count == sent)
        b.setAppActive(true); b.tick(); try wire.drain()
        #expect(b.remote[alice]?.avatarSeed == 246)
        #expect(b.failed.isEmpty && b.loading.isEmpty)
        #expect(wire.sent.allSatisfy { $0.2.kind != .chunk })
    }
}
#endif
