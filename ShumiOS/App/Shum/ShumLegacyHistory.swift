import Foundation
import BitFoundation

// Persisted in ShumDatabase.legacyHistory: keep these types byte-compatible.
struct ShumLegacyContact: Identifiable, Codable, Hashable {
    let id: String // SHA256 of the authenticated Noise public key, never the advertised name.
    var name: String
}
struct ShumLegacyMessage: Identifiable, Codable, Equatable {
    let id: String
    let contactID: String
    let text: String
    let date: Date
    let outgoing: Bool
    var status: DeliveryStatus
    var unread: Bool
}

extension Notification.Name { static let shumOpenChats = Notification.Name("shum.open-chats") }
