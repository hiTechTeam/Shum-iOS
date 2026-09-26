import CryptoKit
import Foundation
import Testing
@testable import Shum

/// Backups must stay restorable across releases, so the file format and the
/// password-based key derivation are pinned here.
@Suite("Shum backup encryption")
@MainActor
struct ShumBackupCryptoTests {
    private func hex(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    @Test("Key derivation matches published PBKDF2-HMAC-SHA256 vectors", arguments: [
        ("password", "salt", 1, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
        ("password", "salt", 2, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
        ("password", "salt", 4096, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
        ("passwd", "salt", 1, "55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc")
    ])
    func keyDerivationMatchesPBKDF2(password: String, salt: String, iterations: Int, expected: String) {
        let key = ShumBackupService.deriveKey(password: password, salt: Data(salt.utf8), iterations: iterations)
        #expect(hex(key) == expected)
    }

    @Test func backupRoundTripsAndExposesOnlyMetadataWithoutPassword() throws {
        let payload = Data("Контакты и переписка".utf8)
        let createdAt = Date(timeIntervalSince1970: 1_790_000_000)
        let backup = try ShumBackupService.encrypt(payload, password: "правильный пароль", createdAt: createdAt, profileName: "Аня")

        #expect(backup.range(of: payload) == nil, "The payload is never stored in clear text")
        let metadata = try ShumBackupService.shared.metadata(for: backup)
        #expect(metadata.profileName == "Аня")
        #expect(metadata.createdAt == createdAt)
        #expect(try ShumBackupService.decrypt(backup, password: "правильный пароль") == payload)
    }

    @Test func wrongPasswordTamperingAndForeignFilesAreRejected() throws {
        let backup = try ShumBackupService.encrypt(Data("секрет".utf8), password: "правильный пароль", createdAt: Date(), profileName: "Аня")

        #expect(throws: ShumBackupError.invalidPassword) {
            _ = try ShumBackupService.decrypt(backup, password: "неверный пароль")
        }
        #expect(throws: ShumBackupError.invalidBackup) {
            _ = try ShumBackupService.decrypt(Data("not a backup".utf8), password: "правильный пароль")
        }

        let magic = Data("SHUM-BACKUP-1\n".utf8)
        func edited(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var envelope = try #require(JSONSerialization.jsonObject(with: backup.dropFirst(magic.count)) as? [String: Any])
            change(&envelope)
            return magic + (try JSONSerialization.data(withJSONObject: envelope))
        }
        let tampered = try edited { envelope in
            var ciphertext = Data(base64Encoded: envelope["ciphertext"] as! String)!
            ciphertext[ciphertext.count / 2] ^= 0x01
            envelope["ciphertext"] = ciphertext.base64EncodedString()
        }
        #expect(throws: (any Error).self) {
            _ = try ShumBackupService.decrypt(tampered, password: "правильный пароль")
        }
        let weakened = try edited { $0["iterations"] = 1 }
        #expect(throws: ShumBackupError.invalidBackup) {
            _ = try ShumBackupService.decrypt(weakened, password: "правильный пароль")
        }
    }

    @Test func passwordRulesAreEnforced() {
        #expect(!ShumBackupService.validPassword("123456789"))
        #expect(ShumBackupService.validPassword("1234567890"))
        #expect(ShumBackupService.validPassword("пароль1234"))
        #expect(ShumBackupService.validPassword(String(repeating: "a", count: 256)))
        #expect(!ShumBackupService.validPassword(String(repeating: "a", count: 257)))
    }

    @Test func restoreAcceptsOnlyKnownFilesInsideTheApp() {
        let photo = String(repeating: "ab", count: 32) + ".jpg"
        for path in ["shum-chats-v1.enc", "ShumConversations/state.enc", "LocalCards-v1/own.json",
                     "LocalCards-v1/peers.json", "ShumProfiles/own.json", "LocalCards-v1/\(photo)"] {
            #expect(ShumBackupService.allowedPath(path), "\(path) should be restorable")
        }
        for path in ["../state.enc", "/ShumConversations/state.enc", "ShumConversations/../state.enc",
                     "Other/state.enc", "ShumConversations/other.enc", "LocalCards-v1/photo.jpg",
                     "LocalCards-v1/nested/own.json", ""] {
            #expect(!ShumBackupService.allowedPath(path), "\(path) must be rejected")
        }
    }
}
