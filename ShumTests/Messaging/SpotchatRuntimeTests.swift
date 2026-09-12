import BitFoundation
import CoreBluetooth
import Foundation
import Testing
@preconcurrency @testable import Shum

@Suite("Spotchat local Bluetooth runtime", .serialized)
@MainActor
struct SpotchatRuntimeTests {
    private let alice = PeerID(str: "1111111111111111")
    private let bob = PeerID(str: "2222222222222222")
    private let eve = PeerID(str: "3333333333333333")

    private func make(_ transport: MockTransport, now: @escaping () -> Date = Date.init) -> SpotchatRuntime {
        let defaults = UserDefaults(suiteName: "SpotchatTests.\(UUID().uuidString)")!
        let model = SpotchatRuntime(transport: transport, defaults: defaults, now: now)
        model.didReceiveTransportEvent(.bluetoothStateUpdated(.poweredOn))
        return model
    }

    private func receive(_ model: SpotchatRuntime, from peer: PeerID, id: String, text: String) throws {
        let data = try #require(PrivateMessagePacket(messageID: id, content: text).encode())
        model.didReceiveTransportEvent(.noisePayloadReceived(peerID: peer, type: .privateMessage, payload: data, timestamp: Date()))
    }

    @Test("Two endpoints exchange private text, acknowledge and suppress duplicates")
    func exchange() throws {
        let a = MockTransport(); a.myPeerID = alice; a.connectedPeers = [bob]
        let b = MockTransport(); b.myPeerID = bob; b.connectedPeers = [alice]
        let left = make(a), right = make(b)
        #expect(left.send("Привет 👋", to: bob))
        let sent = try #require(a.sentPrivateMessages.first)
        try receive(right, from: alice, id: sent.messageID, text: sent.content)
        try receive(right, from: alice, id: sent.messageID, text: sent.content)
        #expect(right.messages.count == 1)
        #expect(right.unreadCount(for: alice) == 1)
        #expect(b.sentDeliveryAcks.count == 2)
        #expect(right.messages.first?.text == "Привет 👋")
        #expect(b.sentReadReceipts.isEmpty)
        left.didReceiveTransportEvent(.noisePayloadReceived(peerID: bob, type: .delivered, payload: Data(sent.messageID.utf8), timestamp: Date()))
        guard case .delivered = left.messages[0].status else { Issue.record("Expected recipient ACK"); return }
        #expect(right.send("Привет в ответ", to: alice))
        let reply = try #require(b.sentPrivateMessages.first)
        try receive(left, from: bob, id: reply.messageID, text: reply.content)
        #expect(left.messages.count == 2)
        #expect(a.sentDeliveryAcks.count == 1)
    }

    @Test("Receipts must come from the recipient; read never regresses")
    func receipts() throws {
        let wire = MockTransport(); wire.connectedPeers = [bob]
        let model = make(wire)
        #expect(model.send("Тест", to: bob))
        let id = try #require(model.messages.first?.id)
        model.didReceiveTransportEvent(.noisePayloadReceived(peerID: eve, type: .readReceipt, payload: Data(id.utf8), timestamp: Date()))
        #expect(model.messages[0].status == .sending)
        model.didReceiveTransportEvent(.noisePayloadReceived(peerID: bob, type: .readReceipt, payload: Data(id.utf8), timestamp: Date()))
        model.didReceiveTransportEvent(.messageDeliveryStatusUpdated(messageID: id, status: .sent))
        model.didReceiveTransportEvent(.noisePayloadReceived(peerID: bob, type: .delivered, payload: Data(id.utf8), timestamp: Date()))
        guard case .read = model.messages[0].status else { Issue.record("Read receipt regressed"); return }
    }

    @Test("Read receipts only when conversation is visible and app active")
    func visibility() throws {
        let wire = MockTransport(); wire.connectedPeers = [bob]
        let model = make(wire)
        model.openConversation(bob)
        model.setAppActive(false)
        try receive(model, from: bob, id: "m1", text: "Фон")
        #expect(wire.sentReadReceipts.isEmpty)
        #expect(model.unreadCount(for: bob) == 1)
        model.setAppActive(true)
        #expect(wire.sentReadReceipts.count == 1)
        #expect(model.unreadCount(for: bob) == 0)
        try receive(model, from: bob, id: "m2", text: "Открытый чат")
        #expect(model.unreadCount(for: bob) == 0)
        model.openConversation(nil)
        try receive(model, from: bob, id: "m3", text: "Новый ответ")
        #expect(model.unreadCount(for: bob) == 1)
        model.openConversation(bob)
        #expect(model.unreadCount(for: bob) == 0)
    }

    @Test("Lost acknowledgements retry the same ID then visibly fail")
    func timeout() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let wire = MockTransport(); wire.connectedPeers = [bob]
        let model = make(wire, now: { clock })
        #expect(model.send("Тест", to: bob))
        for _ in 0..<3 { clock.addTimeInterval(11); model.tick() }
        #expect(wire.sentPrivateMessages.count == 3)
        #expect(Set(wire.sentPrivateMessages.map(\.messageID)).count == 1)
        guard case .failed = model.messages[0].status else { Issue.record("Missing visible timeout"); return }
        let id = model.messages[0].id
        model.didReceiveTransportEvent(.messageDeliveryStatusUpdated(messageID: id, status: .sent))
        guard case .failed = model.messages[0].status else { Issue.record("Late local callback erased timeout"); return }
        model.didReceiveTransportEvent(.noisePayloadReceived(peerID: bob, type: .delivered, payload: Data(id.utf8), timestamp: clock))
        guard case .delivered = model.messages[0].status else { Issue.record("Late real receipt rejected"); return }
    }

    @Test("Mesh-only peers are excluded and direct peers disappear after grace")
    func presence() {
        var clock = Date(timeIntervalSince1970: 1000)
        let wire = MockTransport()
        let model = make(wire, now: { clock })
        model.didUpdatePeerSnapshots([
            .init(peerID: bob, nickname: "Боб", isConnected: true, noisePublicKey: nil, lastSeen: clock),
            .init(peerID: eve, nickname: "Далеко", isConnected: false, noisePublicKey: nil, lastSeen: clock)
        ])
        #expect(model.peers.map(\.id) == [bob])
        clock.addTimeInterval(3); model.didUpdatePeerSnapshots([])
        #expect(model.peers.count == 1)
        clock.addTimeInterval(4); model.didUpdatePeerSnapshots([])
        #expect(model.peers.isEmpty)
    }

    @Test("Multibyte text exceeding wire limit fails visibly without sending")
    func inputBounds() {
        let wire = MockTransport(); wire.connectedPeers = [bob]
        let model = make(wire)
        #expect(!model.send(String(repeating: "🙂", count: 64), to: bob))
        #expect(model.error != nil)
        #expect(wire.sentPrivateMessages.isEmpty)
        #expect(model.send(String(repeating: "я", count: 127), to: bob))
    }
    @Test("Disconnect waits without consuming attempts, reconnect keeps ID, wait is bounded")
    func reconnection() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let wire = MockTransport(); wire.connectedPeers = [bob]
        let model = make(wire, now: { clock })
        #expect(model.send("Переподключение", to: bob))
        let id = try #require(model.messages.first?.id)
        wire.connectedPeers = []
        clock.addTimeInterval(2); model.tick()
        #expect(model.messages[0].waitingForConnection)
        clock.addTimeInterval(45); model.tick()
        #expect(wire.sentPrivateMessages.count == 1)
        #expect(model.messages[0].status == .sending)
        wire.connectedPeers = [bob]; model.tick()
        #expect(wire.sentPrivateMessages.count == 2)
        #expect(Set(wire.sentPrivateMessages.map(\.messageID)) == [id])
        #expect(!model.messages[0].waitingForConnection)
        wire.connectedPeers = []; model.tick()
        clock.addTimeInterval(121); model.tick()
        guard case .failed = model.messages[0].status else { Issue.record("Unbounded offline wait"); return }
        wire.connectedPeers = [bob]
        model.retry(model.messages[0])
        #expect(wire.sentPrivateMessages.last?.messageID == id)
        #expect(model.messages[0].disconnectedWait == 0)
    }

    @Test("Background time cannot exhaust delivery attempts or offline wait")
    func suspension() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let wire = MockTransport(); wire.connectedPeers = [bob]
        let model = make(wire, now: { clock })
        #expect(model.send("Вернусь", to: bob))
        model.setAppActive(false)
        clock.addTimeInterval(3600); model.tick()
        #expect(wire.sentPrivateMessages.count == 1)
        model.setAppActive(true)
        #expect(wire.sentPrivateMessages.count == 1)
        #expect(model.messages[0].status == .sending)
        clock.addTimeInterval(11); model.tick()
        #expect(wire.sentPrivateMessages.count == 2)
        wire.connectedPeers = []; model.tick()
        model.setAppActive(false)
        clock.addTimeInterval(3600); model.tick()
        model.setAppActive(true)
        #expect(model.messages[0].waitingForConnection)
        #expect(model.messages[0].disconnectedWait == 0)
        #expect(wire.stopServicesCallCount == 0)
    }

    @Test("Read receipt retries are bounded and never emitted while backgrounded")
    func boundedReads() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let wire = MockTransport(); wire.connectedPeers = [bob]
        let model = make(wire, now: { clock })
        model.openConversation(bob)
        try receive(model, from: bob, id: "read-retry", text: "Привет")
        for _ in 0..<10 { model.openConversation(bob); model.tick() }
        #expect(wire.sentReadReceipts.count == 1)
        clock.addTimeInterval(11); model.tick()
        #expect(wire.sentReadReceipts.count == 2)
        model.setAppActive(false)
        clock.addTimeInterval(120); model.tick()
        #expect(wire.sentReadReceipts.count == 2)
        try receive(model, from: bob, id: "in-background", text: "Фон")
        #expect(model.unreadCount(for: bob) == 1)
        model.setAppActive(true)
        #expect(model.unreadCount(for: bob) == 0)
        for _ in 0..<10 { clock.addTimeInterval(11); model.tick() }
        #expect(wire.sentReadReceipts.count == 6)
        #expect(model.messages.count == 2)
    }

    @Test("Bluetooth off rejects stale connected snapshots and pauses a failed local write")
    func bluetoothOff() throws {
        let wire = MockTransport(); wire.simulateConnect(bob, nickname: "Боб")
        let model = make(wire)
        #expect(model.send("Тест", to: bob))
        let id = try #require(model.messages.first?.id)
        model.didReceiveTransportEvent(.bluetoothStateUpdated(.poweredOff))
        model.tick()
        #expect(model.peers.isEmpty)
        #expect(model.messages[0].waitingForConnection)
        model.didReceiveTransportEvent(.messageDeliveryStatusUpdated(messageID: id, status: .failed(reason: "No route")))
        #expect(model.messages[0].status == .sending)
        model.didReceiveTransportEvent(.bluetoothStateUpdated(.poweredOn))
        model.tick()
        #expect(model.peers.count == 1)
        #expect(wire.sentPrivateMessages.count == 2)
    }

    @Test("Repeated disconnects cannot replenish the delivery retry budget")
    func flappingLink() throws {
        var clock = Date(timeIntervalSince1970: 1000)
        let wire = MockTransport(); wire.connectedPeers = [bob]
        let model = make(wire, now: { clock })
        #expect(model.send("Повтор", to: bob))
        for _ in 0..<5 {
            wire.connectedPeers = []; clock.addTimeInterval(2); model.tick()
            wire.connectedPeers = [bob]; clock.addTimeInterval(2); model.tick()
        }
        #expect(wire.sentPrivateMessages.count == 3)
        clock.addTimeInterval(11); model.tick()
        guard case .failed = model.messages[0].status else { Issue.record("Unbounded reconnect retries"); return }
    }

}
