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
        let archive = ShumLegacyArchive(contacts: [ShumLegacyContact(id: "stable-noise-fingerprint", name: "Аня")], messages: [
            ShumLegacyMessage(id: "old-id", contactID: "stable-noise-fingerprint", text: "Привет из первой версии", date: Date(), outgoing: false,
                        status: .delivered(to: "Руслан", at: Date()), unread: true)])
        let encrypted = try AES.GCM.seal(JSONEncoder().encode(archive), using: oldKey).combined!
        try encrypted.write(to: oldURL)
        let store = try ShumConversationStore(ownerID: "owner", key: newKey, url: newURL)
        #expect(throws: (any Error).self) {
            try ShumHistoryMigration.migrate(into: store, url: oldURL) { newKey.withUnsafeBytes { Data($0) } }
        }
        #expect(store.state.legacyHistory == nil)
        try ShumHistoryMigration.migrate(into: store, url: oldURL) { oldKey.withUnsafeBytes { Data($0) } }
        #expect(store.state.legacyHistory?.messages.first?.text == archive.messages.first?.text)
        let restored = try ShumConversationStore(ownerID: "owner", key: newKey, url: newURL)
        #expect(restored.state.legacyHistory?.contacts == archive.contacts)
        try ShumHistoryMigration.migrate(into: restored, url: oldURL) { throw ShumFailure.unavailableIdentity }
        #expect(restored.state.legacyHistory?.messages.count == 1)
        #expect(try Data(contentsOf: oldURL) == encrypted)
        #expect(try Data(contentsOf: newURL).range(of: Data(archive.messages[0].text.utf8)) == nil)
    }

    @Test func visibilityCycleDiscardsOldNoiseSessionButKeepsIdentity() throws {
        func node() -> BLEService {
            let keys = MockKeychain()
            return BLEService(keychain: keys, idBridge: NostrIdentityBridge(keychain: keys),
                              identityManager: SecureIdentityStateManager(keys),
                              initializeBluetoothManagers: false)
        }
        let a = node(), b = node()
        let originalKey = a.noiseStaticPublicKeyData()
        a._test_seedConnectedPeer(b.myPeerID, nickname: "Борис")
        b._test_seedConnectedPeer(a.myPeerID, nickname: "Аня")
        let first = try a._test_noiseInitiateHandshake(with: b.myPeerID)
        let second = try #require(try b._test_noiseProcessHandshakeMessage(from: a.myPeerID, message: first))
        let third = try #require(try a._test_noiseProcessHandshakeMessage(from: b.myPeerID, message: second))
        _ = try b._test_noiseProcessHandshakeMessage(from: a.myPeerID, message: third)
        guard case .established = a.getNoiseSessionState(for: b.myPeerID) else {
            Issue.record("Handshake must establish the initial session")
            return
        }
        a.stopServices()
        if case .none = a.getNoiseSessionState(for: b.myPeerID) {} else {
            Issue.record("Visibility off must discard the session invalidated by LEAVE")
        }
        #expect(!a.isPeerConnected(b.myPeerID))
        #expect(a.noiseStaticPublicKeyData() == originalKey)
        b.stopServices()
    }

    @Test func repeatedVisibilityCyclesDoNotSpendHandshakeBudgetOnContinuationPackets() throws {
        func node() -> BLEService {
            let keys = MockKeychain()
            return BLEService(keychain: keys, idBridge: NostrIdentityBridge(keychain: keys),
                              identityManager: SecureIdentityStateManager(keys),
                              initializeBluetoothManagers: false)
        }
        let a = node(), b = node()
        defer { a.stopServices(); b.stopServices() }
        for cycle in 0..<8 {
            a._test_seedConnectedPeer(b.myPeerID, nickname: "B")
            b._test_seedConnectedPeer(a.myPeerID, nickname: "A")
            let first = try a._test_noiseInitiateHandshake(with: b.myPeerID)
            let second = try #require(try b._test_noiseProcessHandshakeMessage(from: a.myPeerID, message: first))
            let third = try #require(try a._test_noiseProcessHandshakeMessage(from: b.myPeerID, message: second))
            _ = try b._test_noiseProcessHandshakeMessage(from: a.myPeerID, message: third)
            #expect(a.noiseSessionPublicKeyData(for: b.myPeerID) == b.noiseStaticPublicKeyData(), "Cycle \(cycle)")
            #expect(b.noiseSessionPublicKeyData(for: a.myPeerID) == a.noiseStaticPublicKeyData(), "Cycle \(cycle)")
            a.stopServices()
            b.stopServices()
        }
    }

    @Test func handshakeFloodBudgetsRemainBoundedAfterSuccessfulReconnects() {
        let peer = PeerID(str: "0123456789abcdef")
        let failed = NoiseRateLimiter()
        for _ in 0..<NoiseSecurityConstants.maxHandshakesPerMinute {
            #expect(failed.allowHandshake(from: peer))
        }
        #expect(!failed.allowHandshake(from: peer))
        let completed = NoiseRateLimiter()
        for _ in 0..<NoiseSecurityConstants.maxGlobalHandshakesPerMinute {
            #expect(completed.allowHandshake(from: peer))
            completed.handshakeSucceeded(with: peer)
        }
        #expect(!completed.allowHandshake(from: peer))
        let packets = NoiseRateLimiter()
        for _ in 0..<(NoiseSecurityConstants.maxHandshakesPerMinute * 3) {
            #expect(packets.allowHandshakeMessage(from: peer, isInitiation: false))
        }
        #expect(!packets.allowHandshakeMessage(from: peer, isInitiation: false))
        let incoming = NoiseRateLimiter()
        for _ in 0..<NoiseSecurityConstants.maxHandshakesPerMinute {
            #expect(incoming.allowHandshakeMessage(from: peer, isInitiation: true))
        }
        #expect(!incoming.allowHandshakeMessage(from: peer, isInitiation: true))
    }

    @Test func visibilityOffDoesNotRestartBluetoothOnForeground() {
        let wire = MockTransport()
        let runtime = ShumRuntime(transport: wire)
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
