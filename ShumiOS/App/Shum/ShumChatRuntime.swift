import SwiftUI
import Combine
import CoreBluetooth
import CryptoKit
import BitFoundation

struct ShumLegacyContact: Identifiable, Codable, Hashable {
    let id: String // SHA256 of the authenticated Noise public key, never the advertised name.
    var name: String
}
struct ShumLegacyMessage: Identifiable, Codable {
    let id: String
    let contactID: String
    let text: String
    let date: Date
    let outgoing: Bool
    var status: DeliveryStatus
    var unread: Bool
}

/// Bluetooth-only composition adapted from ShumRuntime's private-message path.
/// No Internet transport, relay client, gateway or location service is instantiated.
@MainActor
final class ShumChatRuntime: ObservableObject, TransportEventDelegate, TransportPeerEventsDelegate {
    @Published private(set) var contacts: [ShumLegacyContact] = []
    @Published private(set) var messages: [ShumLegacyMessage] = []
    @Published private(set) var nearbyIDs: Set<String> = []
    @Published private(set) var bluetoothState: CBManagerState = .unknown
    @Published var error: String?
    private var transport: Transport?
    private var sessions: [String: PeerID] = [:]
    private var activeContact: String?
    private var active = true
    private var enabled = false
    private var nickname = "Гость".localized
    private var timer: AnyCancellable?
    private var storageKey: SymmetricKey?
    private var storageAvailable = false
    private let historyURL: URL
    private var previewMode = false
    private struct Archive: Codable { var contacts: [ShumLegacyContact]; var messages: [ShumLegacyMessage] }

    init(transport: Transport? = nil, historyURL: URL? = nil, key: SymmetricKey? = nil) {
        self.transport = transport
        self.historyURL = historyURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("shum-chats-v1.enc")
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-ShumPreview") {
            previewMode = true
            for (index, name) in ["Аня", "Саша", "Друзья", "Маша", "Команда", "Денис", "Лиза"].enumerated() {
                let id = "preview-\(index)"
                contacts.append(ShumLegacyContact(id: id, name: name))
                nearbyIDs.insert(id)
                messages.append(ShumLegacyMessage(id: UUID().uuidString, contactID: id,
                    text: ["Увидимся у входа?", "Фото просто огонь", "Я уже на месте", "До встречи!", "Всё готово", "Спасибо! До завтра", "Давай на выходных"][index],
                    date: Date().addingTimeInterval(Double(-index * 3600)), outgoing: index % 2 == 1,
                    status: .delivered(to: name, at: Date()), unread: index == 0 || index == 2))
            }
            bluetoothState = .poweredOn
            return
        }
        #endif
        do {
            let suppliedKey = key
            let key: Data
            if let suppliedKey { key = suppliedKey.withUnsafeBytes { Data($0) } }
            else if let saved = try KeychainStore.shared.data(for: "shum.chat.storage-key") { key = saved }
            else {
                guard !FileManager.default.fileExists(atPath: self.historyURL.path) else { throw CocoaError(.fileReadCorruptFile) }
                key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                try KeychainStore.shared.set(key, for: "shum.chat.storage-key")
            }
            guard key.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
            storageKey = SymmetricKey(data: key)
            if FileManager.default.fileExists(atPath: self.historyURL.path) {
                let bytes = try Data(contentsOf: self.historyURL)
                let decoded = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: storageKey!)
                let saved = try JSONDecoder().decode(Archive.self, from: decoded)
                contacts = saved.contacts; messages = saved.messages
                for i in messages.indices where messages[i].outgoing {
                    if case .sending = messages[i].status { messages[i].status = .failed(reason: "Отправка прервана".localized) }
                }
            }
            storageAvailable = true
        } catch { self.error = "Не удалось открыть историю чатов. Данные сохранены без изменений.".localized }
        timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.expirePendingMessages()
        }
    }

    func configure(name: String, enabled: Bool, active: Bool) {
        guard !previewMode else { return }
        nickname = String(name.prefix(32)); self.active = active
        self.enabled = enabled
        guard enabled, storageAvailable else {
            transport?.stopServices(); nearbyIDs = []; sessions = [:]; return
        }
        if transport == nil {
            let keychain = KeychainManager.makeDefault()
            let ble = BitchatTransportFactory.make(keychain: keychain)
            ble.eventDelegate = self; ble.peerEventsDelegate = self
            ble.addPeerAuthenticatedObserver { [weak self] _, _ in
                Task { @MainActor in
                    guard let self, let transport = self.transport else { return }
                    self.didUpdatePeerSnapshots(transport.currentPeerSnapshots())
                }
            }
            transport = ble
        }
        transport?.eventDelegate = self
        transport?.peerEventsDelegate = self
        transport?.setNickname(nickname)
        transport?.startServices()
        if let radio = transport as? BluetoothStateReporting { bluetoothState = radio.getCurrentBluetoothState() }
        if active, let activeContact { markRead(activeContact) }
    }

    func didUpdatePeerSnapshots(_ snapshots: [TransportPeerSnapshot]) {
        guard enabled, let transport else { return }
        let previousContacts = contacts
        var current: [String: PeerID] = [:]
        for snapshot in snapshots.prefix(60) where snapshot.isConnected || transport.isPeerReachable(snapshot.peerID) {
            guard let key = transport.noiseSessionPublicKeyData(for: snapshot.peerID) else {
                transport.triggerHandshake(with: snapshot.peerID); continue
            }
            let id = Self.fingerprint(key)
            current[id] = snapshot.peerID
            upsert(id: id, name: snapshot.nickname)
        }
        sessions = current; nearbyIDs = Set(current.keys)
        if contacts != previousContacts { persist() }
    }
    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func upsert(id: String, name: String) {
        let name = String(name.prefix(64))
        if let i = contacts.firstIndex(where: { $0.id == id }) { if contacts[i].name != name { contacts[i].name = name } }
        else if contacts.count < 1000 { contacts.append(ShumLegacyContact(id: id, name: name)) }
    }
    func conversation(_ id: String) -> [ShumLegacyMessage] { messages.filter { $0.contactID == id } }
    func unread(_ id: String) -> Int { messages.filter { $0.contactID == id && $0.unread }.count }
    var unreadCount: Int { messages.filter(\.unread).count }
    var chatContacts: [ShumLegacyContact] {
        contacts.filter { id in messages.contains { $0.contactID == id.id } }.sorted {
            (conversation($0.id).last?.date ?? .distantPast) > (conversation($1.id).last?.date ?? .distantPast)
        }
    }
    func name(_ id: String) -> String { contacts.first { $0.id == id }?.name ?? "Собеседник".localized }
    @discardableResult func send(_ text: String, to id: String) -> Bool {
        let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return false }
        guard content.utf8.count <= 255 else { error = "Пока можно отправить до 255 байт текста. Разделите сообщение на несколько частей.".localized; return false }
        guard storageAvailable, enabled, let transport, let peer = sessions[id], transport.isPeerReachable(peer),
              let key = transport.noiseSessionPublicKeyData(for: peer), Self.fingerprint(key) == id else {
            error = "Собеседник сейчас недоступен. Дождитесь подключения по Bluetooth.".localized; return false
        }
        let message = ShumLegacyMessage(id: UUID().uuidString, contactID: id, text: content, date: Date(), outgoing: true, status: .sending, unread: false)
        messages.append(message)
        guard persist() else { messages.removeAll { $0.id == message.id }; return false }
        transport.sendPrivateMessage(content, to: peer, recipientNickname: name(id), messageID: message.id)
        return true
    }
    func open(_ id: String?) { activeContact = id; if let id { markRead(id) } }
    private func markRead(_ id: String) {
        guard active else { return }
        let unreadMessages = conversation(id).filter { !$0.outgoing && $0.unread }
        for i in messages.indices where messages[i].contactID == id { messages[i].unread = false }
        guard persist(), let transport, let peer = sessions[id] else { return }
        for message in unreadMessages {
            transport.sendReadReceipt(ReadReceipt(originalMessageID: message.id, readerID: transport.myPeerID, readerNickname: nickname), to: peer)
        }
    }
    func didReceiveTransportEvent(_ event: TransportEvent) {
        guard enabled, let transport else { return }
        switch event {
        case .bluetoothStateUpdated(let state):
            bluetoothState = state
            if state != .poweredOn { nearbyIDs = []; sessions = [:] }
        case .peerSnapshotsUpdated(let snapshots): didUpdatePeerSnapshots(snapshots)
        case .peerConnected, .peerDisconnected, .peerListUpdated: didUpdatePeerSnapshots(transport.currentPeerSnapshots())
        case let .noisePayloadReceived(peer, type, payload, date):
            guard let key = transport.noiseSessionPublicKeyData(for: peer) else { return }
            let contactID = Self.fingerprint(key)
            sessions[contactID] = peer; nearbyIDs.insert(contactID)
            upsert(id: contactID, name: transport.peerNickname(peerID: peer) ?? "Собеседник".localized)
            switch type {
            case .privateMessage:
                guard let packet = PrivateMessagePacket.decode(from: payload), !packet.messageID.isEmpty,
                      packet.messageID.utf8.count <= 255, !packet.content.isEmpty, packet.content.utf8.count <= 255 else { return }
                if !messages.contains(where: { $0.id == packet.messageID && $0.contactID == contactID && !$0.outgoing }) {
                    messages.append(ShumLegacyMessage(id: packet.messageID, contactID: contactID, text: packet.content, date: date, outgoing: false,
                        status: .delivered(to: nickname, at: Date()), unread: true))
                    guard persist() else { messages.removeLast(); return }
                }
                transport.sendDeliveryAck(for: packet.messageID, to: peer)
                if activeContact == contactID { markRead(contactID) }
            case .delivered, .readReceipt:
                guard let id = String(data: payload, encoding: .utf8), let i = messages.firstIndex(where: { $0.id == id && $0.contactID == contactID && $0.outgoing }) else { return }
                if case .read = messages[i].status { return }
                messages[i].status = type == .readReceipt ? .read(by: name(contactID), at: Date()) : .delivered(to: name(contactID), at: Date())
                persist()
            default: break
            }
        case let .messageDeliveryStatusUpdated(id, status):
            guard let i = messages.firstIndex(where: { $0.id == id && $0.outgoing }) else { return }
            switch messages[i].status {
            case .sending, .sent:
                switch status { case .sent, .failed: messages[i].status = status; persist(); default: break }
            default: break
            }
        default: break
        }
    }
    private func expirePendingMessages() {
        var changed = false
        for i in messages.indices where messages[i].outgoing && Date().timeIntervalSince(messages[i].date) > 60 {
            switch messages[i].status {
            case .sending: messages[i].status = .failed(reason: "Нет подтверждения отправки".localized); changed = true
            default: break
            }
        }
        if changed { persist() }
        if enabled, let transport { didUpdatePeerSnapshots(transport.currentPeerSnapshots()) }
    }
    @discardableResult private func persist() -> Bool {
        guard storageAvailable, let storageKey else { return false }
        do {
            let data = try JSONEncoder().encode(Archive(contacts: contacts, messages: messages))
            let sealed = try AES.GCM.seal(data, using: storageKey)
            try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try sealed.combined!.write(to: historyURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { self.error = "Не удалось сохранить переписку. Проверьте свободное место.".localized; return false }
    }
    func reset() throws {
        enabled = false; transport?.stopServices()
        if FileManager.default.fileExists(atPath: self.historyURL.path) { try FileManager.default.removeItem(at: historyURL) }
        (transport as? PanicResettingTransport)?.resetIdentityForPanic(currentNickname: "Гость".localized, restartServices: false)
        contacts = []; messages = []; sessions = [:]; nearbyIDs = []; activeContact = nil
    }
}

extension Notification.Name { static let shumOpenChats = Notification.Name("shum.open-chats") }
