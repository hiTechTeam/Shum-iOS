import CryptoKit
import Foundation
import SQLite3
import Testing
@preconcurrency @testable import Shum

@Suite("Encrypted SQLite persistence", .serialized)
@MainActor
struct ShumSQLiteTests {
    @Test func updateAppendAndReorderAfterDeletionRestoreExactly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.enc")
        let clock = ShumPermanentTests.Clock()
        let a = try ShumPermanentTests.Node("Alice", clock: clock, url: url)
        let b = try ShumPermanentTests.Node("Bob", clock: clock)
        try ShumPermanentTests().allowBoth(a, b, clock: clock)
        #expect(a.service.send("History", to: b.card))
        let template = try #require(a.store.state.messages.first)
        try a.store.transaction { state in
            state.messages = ["a", "b", "c"].map { id in
                var message = template
                message.envelope.id = id
                return message
            }
        }
        try a.store.transaction { $0.messages.removeFirst() }
        try a.store.transaction { state in
            state.messages[0].text = "Edited"
            var appended = template
            appended.envelope.id = "d"
            state.messages.append(appended)
        }
        var restored = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(restored.state == a.store.state)
        #expect(restored.state.messages.map(\.id) == ["b", "c", "d"])
        try a.store.transaction { $0.messages.reverse() }
        restored = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(restored.state == a.store.state)
        let beforeDuplicate = a.store.state
        let commits = a.store.committedTransactions
        #expect(throws: (any Error).self) {
            try a.store.transaction { $0.messages.append($0.messages[0]) }
        }
        #expect(a.store.state == beforeDuplicate)
        #expect(a.store.committedTransactions == commits)
        restored = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(restored.state == beforeDuplicate)
    }
    private func sql(_ query: String, at url: URL) throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, query, nil, nil, nil) == SQLITE_OK)
    }
    @Test func oldSnapshotMigratesAndPortableBackupContainsLatestState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.enc")
        let clock = ShumPermanentTests.Clock()
        let a = try ShumPermanentTests.Node("Alice", clock: clock)
        let b = try ShumPermanentTests.Node("Bob", clock: clock)
        try ShumPermanentTests().allowBoth(a, b, clock: clock)
        #expect(a.service.send("Старое сообщение", to: b.card))
        let original = try ChaChaPoly.seal(ShumCoding.encode(a.store.state), using: a.identity.storageKey).combined
        try original.write(to: url)
        let store = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(store.state.messages == a.store.state.messages)
        #expect(try Data(contentsOf: url.appendingPathExtension("v1-recovery")) == original)
        try store.transaction { $0.messages[0].text = "После миграции" }
        let portable = try ShumConversationStore.encryptedSnapshot(at: url, key: a.identity.storageKey)
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: portable), using: a.identity.storageKey)
        let restored = try JSONDecoder().decode(ShumDatabase.self, from: plain)
        #expect(restored == store.state)
        let reopened = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(reopened.state == store.state)
        for suffix in ["", "-wal"] {
            if let raw = try? Data(contentsOf: URL(fileURLWithPath: url.path + suffix)) {
                #expect(raw.range(of: Data("После миграции".utf8)) == nil)
                #expect(raw.range(of: Data(b.card.id.utf8)) == nil)
                #expect(raw.range(of: Data(store.state.messages[0].id.utf8)) == nil)
            }
        }
    }
    @Test func failedInsertCannotPublishOrAcknowledgeIncomingMessage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.enc")
        let clock = ShumPermanentTests.Clock()
        let a = try ShumPermanentTests.Node("Alice", clock: clock, url: url)
        let b = try ShumPermanentTests.Node("Bob", clock: clock)
        try ShumPermanentTests().allowBoth(a, b, clock: clock)
        #expect(b.service.send("Must persist first", to: a.card))
        let envelope = try #require(b.store.state.messages.first?.envelope)
        try sql("CREATE TRIGGER refuse_message BEFORE INSERT ON records WHEN NEW.bucket='messages' BEGIN SELECT RAISE(ABORT,'disk failure'); END", at: url)
        a.service.receive(ShumPacket(envelope: envelope), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.store.state.messages.isEmpty)
        #expect(a.store.state.receipts.isEmpty)
        #expect(a.wire.shumPackets.isEmpty)
        let reopened = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(reopened.state.messages.isEmpty)
        #expect(reopened.state.receipts.isEmpty)
        try sql("DROP TRIGGER refuse_message", at: url)
        a.service.receive(ShumPacket(envelope: envelope), from: nil, nostrSender: b.card.nostrKey)
        #expect(a.store.state.messages.count == 1)
        #expect(a.store.state.receipts.count == 1)
    }
    @Test func deletedEncryptedRecordFailsClosed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.enc")
        let clock = ShumPermanentTests.Clock()
        let a = try ShumPermanentTests.Node("Alice", clock: clock, url: url)
        let b = try ShumPermanentTests.Node("Bob", clock: clock)
        try ShumPermanentTests().allowBoth(a, b, clock: clock)
        #expect(a.service.send("Keep me", to: b.card))
        try sql("DELETE FROM records WHERE bucket='messages'", at: url)
        #expect(throws: (any Error).self) {
            _ = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        }
    }
    @Test func removingFirstMessageDoesNotRewriteSurvivingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.enc")
        let clock = ShumPermanentTests.Clock()
        let a = try ShumPermanentTests.Node("Alice", clock: clock, url: url)
        let b = try ShumPermanentTests.Node("Bob", clock: clock)
        try ShumPermanentTests().allowBoth(a, b, clock: clock)
        #expect(a.service.send("History", to: b.card))
        let template = try #require(a.store.state.messages.first)
        try a.store.transaction { state in
            state.messages = (0..<1000).map { index in
                var copy = template
                copy.envelope.id = "stored-test-" + String(index)
                return copy
            }
        }
        let writes = a.store.committedRows
        try a.store.transaction { $0.messages.removeFirst() }
        #expect(a.store.committedRows - writes == 2, "One deleted row and the authenticated counts header")
        let restored = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(restored.state.messages == a.store.state.messages)
    }

    @Test func droppedLegacyFieldsAreRemovedFromSQLiteBeforeTheNextCommit() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("state.enc")
        let clock = ShumPermanentTests.Clock()
        let a = try ShumPermanentTests.Node("Alice", clock: clock, url: url)
        let b = try ShumPermanentTests.Node("Bob", clock: clock)
        try a.store.transaction { $0.savedProfiles = [ShumSavedProfile(card: b.card, savedAt: clock.date)] }
        let restored = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(restored.state.savedProfiles == nil)
        try restored.transaction { $0.deletedMessageIDs = ["deleted": clock.date] }
        let reopened = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(reopened.state == restored.state)
    }

}
