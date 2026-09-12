import Foundation
import CryptoKit
import BitFoundation
import Testing
@testable import Shum

@MainActor
@Suite("Shum Bluetooth chat", .serialized)
struct ShumChatTests {
    private func make(_ wire: ShumTestTransport, url: URL, key: SymmetricKey) -> ShumChatRuntime {
        let runtime = ShumChatRuntime(transport: wire, historyURL: url, key: key)
        runtime.configure(name: "Тест", enabled: true, active: true)
        runtime.didUpdatePeerSnapshots(wire.currentPeerSnapshots())
        return runtime
    }
    @Test func rejectsOversizedUnicodeAndDisconnectedSends() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wire = ShumTestTransport()
        let model = make(wire, url: directory.appendingPathComponent("history"), key: SymmetricKey(size: .bits256))
        let id = try #require(model.contacts.first?.id)
        #expect(!model.send(String(repeating: "я", count: 128), to: id))
        #expect(wire.sent.isEmpty)
        #expect(model.send(String(repeating: "я", count: 127), to: id))
        #expect(wire.sent.count == 1)
        wire.connected = false
        #expect(!model.send("Привет", to: id))
        #expect(wire.sent.count == 1)
    }
    @Test func authenticatedReceiptCannotAcknowledgeAnotherContact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wire = ShumTestTransport()
        let model = make(wire, url: directory.appendingPathComponent("history"), key: SymmetricKey(size: .bits256))
        let id = try #require(model.contacts.first?.id)
        #expect(model.send("Привет", to: id))
        let sent = try #require(wire.sent.first)
        model.didReceiveTransportEvent(.noisePayloadReceived(peerID: wire.other, type: .readReceipt, payload: Data(sent.utf8), timestamp: Date()))
        #expect(model.messages.first?.status == .sending)
        model.didReceiveTransportEvent(.noisePayloadReceived(peerID: wire.peer, type: .delivered, payload: Data(sent.utf8), timestamp: Date()))
        if case .delivered = model.messages.first?.status {} else { Issue.record("Expected authenticated delivery receipt") }
        model.didReceiveTransportEvent(.messageDeliveryStatusUpdated(messageID: sent, status: .sent))
        if case .delivered = model.messages.first?.status {} else { Issue.record("Local status must not overwrite delivery") }
    }
    @Test func duplicateIncomingMessageStoredOnceAndHistoryEncrypted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history")
        let key = SymmetricKey(size: .bits256)
        let wire = ShumTestTransport()
        let model = make(wire, url: url, key: key)
        let packet = PrivateMessagePacket(messageID: "message-1", content: "Секретная переписка")
        let bytes = try #require(packet.encode())
        for _ in 0..<2 { model.didReceiveTransportEvent(.noisePayloadReceived(peerID: wire.peer, type: .privateMessage, payload: bytes, timestamp: Date())) }
        #expect(model.messages.count == 1)
        #expect(wire.acks.count == 2)
        #expect(model.unreadCount == 1)
        let ciphertext = try Data(contentsOf: url)
        #expect(ciphertext.range(of: Data("Секретная переписка".utf8)) == nil)
        let restored = make(wire, url: url, key: key)
        #expect(restored.messages.count == 1)
        #expect(restored.messages.first?.text == "Секретная переписка")
        let id = try #require(restored.contacts.first?.id)
        restored.open(id)
        #expect(restored.unreadCount == 0)
        #expect(wire.reads.count == 1)
        try restored.reset()
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(restored.messages.isEmpty)
    }
}

private final class ShumTestTransport: Transport {
    weak var delegate: BitchatDelegate?
    weak var eventDelegate: TransportEventDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    let myPeerID = PeerID(str: "0000000000000000")
    let peer = PeerID(str: "1111111111111111")
    let other = PeerID(str: "2222222222222222")
    var myNickname = "Тест"
    var connected = true
    var sent: [String] = []
    var acks: [String] = []
    var reads: [String] = []
    func currentPeerSnapshots() -> [TransportPeerSnapshot] {
        [TransportPeerSnapshot(peerID: peer, nickname: "Аня", isConnected: connected, noisePublicKey: nil, lastSeen: Date())]
    }
    func noiseSessionPublicKeyData(for id: PeerID) -> Data? { Data(repeating: id == peer ? 1 : 2, count: 32) }
    func setNickname(_ nickname: String) { myNickname = nickname }
    func startServices() {}
    func stopServices() {}
    func emergencyDisconnectAll() {}
    func isPeerConnected(_ peerID: PeerID) -> Bool { connected }
    func isPeerReachable(_ peerID: PeerID) -> Bool { connected }
    func peerNickname(peerID: PeerID) -> String? { "Аня" }
    func getPeerNicknames() -> [PeerID: String] { [peer: "Аня"] }
    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) {}
    func sendMessage(_ content: String, mentions: [String]) {}
    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) { sent.append(messageID) }
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) { reads.append(receipt.originalMessageID) }
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
    func sendBroadcastAnnounce() {}
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) { acks.append(messageID) }
}
