import BitFoundation
import Foundation

/// History from the first build, which stored no signed contact cards. It is
/// shown as read-only local history; no signed contact is ever made from it.
struct ShumLegacyArchive: Codable, Equatable {
    var contacts: [ShumLegacyContact]
    var messages: [ShumLegacyMessage]
    static func peerID(_ contactID: String) -> PeerID { PeerID(str: "legacy-" + contactID) }
}
