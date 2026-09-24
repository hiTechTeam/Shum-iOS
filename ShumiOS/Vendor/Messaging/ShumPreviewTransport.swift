#if DEBUG && targetEnvironment(simulator)
import BitFoundation
import Foundation

/// Opt-in UI fixtures. Compiled only into simulator Debug builds; no radio or user data.
final class ShumPreviewTransport: Transport {
    weak var delegate: BitchatDelegate?
    weak var eventDelegate: TransportEventDelegate?
    weak var peerEventsDelegate: TransportPeerEventsDelegate?
    let myPeerID = PeerID(str: "0000000000000000")
    var myNickname = "Руслан"
    private static var sampleNames: [String] {
        let initial = ["Аня", "Дима", "Маша", "Саша"]
        guard ProcessInfo.processInfo.arguments.contains("-ShumPreviewLongList") else { return initial }
        return initial + [
            "Александр", "Алексей", "Алина", "Андрей", "Антон", "Артём",
            "Валерия", "Василий", "Вера", "Виктор", "Виктория", "Глеб",
            "Дарья", "Денис", "Евгения", "Егор", "Екатерина", "Елена",
            "Иван", "Игорь", "Илья", "Ирина", "Кирилл", "Ксения",
            "Лев", "Лиза", "Максим", "Марина", "Михаил", "Наталья",
            "Никита", "Олег", "Ольга", "Павел", "Полина", "Роман",
            "Сергей", "Соня", "Татьяна", "Тимур", "Юлия", "Ярослав"
        ]
    }
    let samples: [TransportPeerSnapshot] = sampleNames.enumerated().map {
        let id = $0.offset < 4
            ? String(repeating: String($0.offset + 1), count: 16)
            : "eeeeeeeeeeee" + String(format: "%04x", $0.offset)
        return TransportPeerSnapshot(peerID: PeerID(str: id),
            nickname: $0.element, isConnected: true, noisePublicKey: nil, lastSeen: Date(),
            distanceMeters: [2, 5, 8, 12][$0.offset % 4])
    }
    func currentPeerSnapshots() -> [TransportPeerSnapshot] { samples }
    func setNickname(_ nickname: String) { myNickname = nickname }
    func startServices() {}
    func stopServices() {}
    func emergencyDisconnectAll() {}
    func isPeerConnected(_ peerID: PeerID) -> Bool { samples.contains { $0.peerID == peerID } }
    func isPeerReachable(_ peerID: PeerID) -> Bool { isPeerConnected(peerID) }
    func peerNickname(peerID: PeerID) -> String? { samples.first { $0.peerID == peerID }?.nickname }
    func getPeerNicknames() -> [PeerID: String] { Dictionary(uniqueKeysWithValues: samples.map { ($0.peerID, $0.nickname) }) }
    func getFingerprint(for peerID: PeerID) -> String? { nil }
    func getNoiseSessionState(for peerID: PeerID) -> LazyHandshakeState { .none }
    func triggerHandshake(with peerID: PeerID) {}
    func sendMessage(_ content: String, mentions: [String]) {}
    func sendPrivateMessage(_ content: String, to peerID: PeerID, recipientNickname: String, messageID: String) {
        Task { @MainActor [weak self] in
            self?.eventDelegate?.didReceiveTransportEvent(.noisePayloadReceived(peerID: peerID,
                type: .readReceipt, payload: Data(messageID.utf8), timestamp: Date()))
        }
    }
    func sendReadReceipt(_ receipt: ReadReceipt, to peerID: PeerID) {}
    func sendFavoriteNotification(to peerID: PeerID, isFavorite: Bool) {}
    func sendBroadcastAnnounce() {}
    func sendDeliveryAck(for messageID: String, to peerID: PeerID) {}
}
#endif
