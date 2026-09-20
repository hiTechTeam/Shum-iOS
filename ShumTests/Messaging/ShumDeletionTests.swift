import Foundation
import Testing
@preconcurrency @testable import Shum

@Suite("Shum profile deletion", .serialized)
@MainActor
struct ShumDeletionTests {
    @Test func deletionIsRetryableAndKeepsIdentityClosedUntilExplicitNewProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("privacy/deletion.state")
        let profile = root.appendingPathComponent("profile.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("private profile".utf8).write(to: profile)
        let keychain = MockKeychain()
        _ = keychain.saveIdentityKey(Data([1,2,3]), forKey: "noiseStaticKey")
        var clearedPreferences = false
        let service = ShumDeletionService(marker: marker, directories: [root], deleteKeys: { keychain.deleteAllKeychainData() }, clearPreferences: { clearedPreferences = true })
        try service.begin()
        keychain.simulatedDeleteAllResult = false
        #expect(throws: (any Error).self) { try service.finish() }
        #expect(service.hasDeletion && !service.completed)
        #expect(!clearedPreferences)
        #expect(throws: (any Error).self) { try service.allowNewProfile() }
        keychain.simulatedDeleteAllResult = true
        let restarted = ShumDeletionService(marker: marker, directories: [root], deleteKeys: { keychain.deleteAllKeychainData() }, clearPreferences: { clearedPreferences = true })
        try restarted.finish()
        #expect(restarted.completed)
        #expect(!FileManager.default.fileExists(atPath: profile.path))
        #expect(keychain.getIdentityKey(forKey: "noiseStaticKey") == nil)
        #expect(clearedPreferences)
        try restarted.allowNewProfile()
        #expect(!restarted.hasDeletion)
    }
}
