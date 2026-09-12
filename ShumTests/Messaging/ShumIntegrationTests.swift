import BitFoundation
import CryptoKit
import Foundation
import Testing
@preconcurrency @testable import Shum

@Suite("Shum upgrades and lifecycle", .serialized)
@MainActor
struct ShumIntegrationTests {
    @Test func oldEncryptedHistoryMigratesOnceAndRejectsWrongKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldKey = SymmetricKey(size: .bits256), newKey = SymmetricKey(size: .bits256)
        let oldURL = root.appendingPathComponent("old.enc"), newURL = root.appendingPathComponent("new.enc")
        let archive = ShumLegacyArchive(contacts: [ShumContact(id: "stable-noise-fingerprint", name: "Аня")], messages: [
            ShumMessage(id: "old-id", contactID: "stable-noise-fingerprint", text: "Привет из первой версии", date: Date(), outgoing: false,
                        status: .delivered(to: "Руслан", at: Date()), unread: true)])
        let encrypted = try AES.GCM.seal(JSONEncoder().encode(archive), using: oldKey).combined!
        try encrypted.write(to: oldURL)
        let store = try SpotchatConversationStore(ownerID: "owner", key: newKey, url: newURL)
        #expect(throws: (any Error).self) {
            try ShumHistoryMigration.migrate(into: store, url: oldURL) { newKey.withUnsafeBytes { Data($0) } }
        }
        #expect(store.state.legacyHistory == nil)
        try ShumHistoryMigration.migrate(into: store, url: oldURL) { oldKey.withUnsafeBytes { Data($0) } }
        #expect(store.state.legacyHistory?.messages.first?.text == archive.messages.first?.text)
        let restored = try SpotchatConversationStore(ownerID: "owner", key: newKey, url: newURL)
        #expect(restored.state.legacyHistory?.contacts == archive.contacts)
        try ShumHistoryMigration.migrate(into: restored, url: oldURL) { throw SpotchatFailure.unavailableIdentity }
        #expect(restored.state.legacyHistory?.messages.count == 1)
        #expect(try Data(contentsOf: oldURL) == encrypted)
        #expect(try Data(contentsOf: newURL).range(of: Data(archive.messages[0].text.utf8)) == nil)
    }

    @Test func visibilityOffDoesNotRestartBluetoothOnForeground() {
        let wire = MockTransport()
        let runtime = SpotchatRuntime(transport: wire)
        runtime.setBluetoothEnabled(false)
        runtime.start(runTimer: false)
        runtime.setAppActive(false)
        runtime.setAppActive(true)
        #expect(wire.startServicesCallCount == 0)
        runtime.setBluetoothEnabled(true)
        #expect(wire.startServicesCallCount == 1)
        runtime.retireForDeletion()
        runtime.setBluetoothEnabled(true)
        runtime.setAppActive(true)
        runtime.start(runTimer: false)
        #expect(wire.startServicesCallCount == 1)
    }
}
