import CryptoKit
import Foundation
import Darwin
import SQLite3

/// A private serial SQLite connection. Payloads (including metadata) are
/// authenticated ciphertext; SQLite and its WAL never contain message text.
/// FULL synchronous commits precede publication/ACK. Checkpoints run here,
/// not in the UI. v1 portable snapshots remain the backup interchange format.
final class ShumSQLitePersistence: @unchecked Sendable {
    private struct Header: Codable, Equatable {
        var state: ShumDatabase
        var counts: [String: Int]
    }
    private struct Row {
        var bucket: String
        var id: String
        var position: Int
        var indexID: String? = nil
        var payload: Data?
        var token: String { bucket + "\0" + id }
        var aad: Data { Data((bucket + "\0" + (indexID ?? id) + "\0" + String(position)).utf8) }
    }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let signature = Data("SQLite format 3\0".utf8)
    private let queue = DispatchQueue(label: "shum.sqlite", qos: .userInitiated)
    // Serialize writers and checkpoints across all connections to one file.
    // Readers remain concurrent. This also avoids the WAL-reset race on
    // older system SQLite builds: sqlite.org/wal.html#the_wal_reset_bug.
    private final class Writers: @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: DispatchQueue] = [:]
        func queue(for url: URL) -> DispatchQueue {
            lock.lock(); defer { lock.unlock() }
            let path = url.standardizedFileURL.path
            if let queue = queues[path] { return queue }
            let queue = DispatchQueue(label: "shum.sqlite.writer", qos: .userInitiated)
            queues[path] = queue
            return queue
        }
    }
    private static let writers = Writers()
    private let writerQueue: DispatchQueue
    private let key: SymmetricKey
    private let url: URL
    private let ownerID: String
    private var db: OpaquePointer?
    private var sizes: [String: Int] = [:]
    private var positions: [String: Int] = [:]
    private var committedCount = 0
    private var writtenRows = 0
    var committedTransactions: Int { queue.sync { committedCount } }
    var committedRows: Int { queue.sync { writtenRows } }
    private var totalBytes = 0
    private var headerExists = false

    init(ownerID: String, key: SymmetricKey, url: URL, atomicCreation: Bool = true) throws {
        self.ownerID = ownerID; self.key = key; self.url = url
        writerQueue = Self.writers.queue(for: url)
        try Self.prepareDirectory(url.deletingLastPathComponent())
        try writerQueue.sync {
            if atomicCreation, !FileManager.default.fileExists(atPath: url.path) {
                let temporary = url.appendingPathExtension("creation-" + UUID().uuidString)
                defer { Self.removeFiles(temporary) }
                let created = try ShumSQLitePersistence(ownerID: ownerID, key: key, url: temporary, atomicCreation: false)
                created.close()
                guard rename(temporary.path, url.path) == 0 else { throw ShumFailure.storage }
            }
            if FileManager.default.fileExists(atPath: url.path), try !Self.isSQLite(url) {
                let data = try Data(contentsOf: url)
                guard data.count <= 100_000_000 else { throw ShumFailure.storage }
                let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key)
                let legacy = try Self.normalize(JSONDecoder().decode(ShumDatabase.self, from: plain), ownerID: ownerID)
                // The old file stays intact until a complete encrypted database has
                // been committed, checkpointed and closed. Rename is atomic.
                let temporary = url.appendingPathExtension("migration-" + UUID().uuidString)
                defer { Self.removeFiles(temporary) }
                let migration = try ShumSQLitePersistence(ownerID: ownerID, key: key, url: temporary)
                try migration.commit(previous: ShumDatabase(ownerID: ownerID), next: legacy)
                migration.close()
                let recovery = url.appendingPathExtension("v1-recovery")
                if !FileManager.default.fileExists(atPath: recovery.path) {
                    try FileManager.default.copyItem(at: url, to: recovery)
                }
                guard rename(temporary.path, url.path) == 0 else { throw ShumFailure.storage }
            }
        }
        try queue.sync {
            let exists = FileManager.default.fileExists(atPath: url.path)
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
                throw ShumFailure.storage
            }
            do {
                if exists {
                    let header = try readHeader()
                    _ = try Self.normalize(header.state, ownerID: ownerID)
                    headerExists = true
                }
                try writerQueue.sync {
                    try execute("PRAGMA journal_mode=WAL")
                    try execute("PRAGMA synchronous=FULL")
                    try execute("PRAGMA secure_delete=ON")
                    sqlite3_busy_timeout(db, 1000)
                    if !exists {
                        try execute("CREATE TABLE records (bucket TEXT NOT NULL, id TEXT NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(bucket,id)) WITHOUT ROWID")
                        try execute("PRAGMA user_version=1")
                    }
                }
                if !headerExists {
                    let empty = ShumDatabase(ownerID: ownerID, invitationStates: [:], invitationOutbox: [])
                    try commitOnQueue(previous: empty, next: empty)
                }
            } catch {
                writerQueue.sync { sqlite3_close(db) }; db = nil
                throw error
            }
        }
    }
    deinit { close() }
    func close() {
        queue.sync {
            writerQueue.sync {
                if let db { sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil); sqlite3_close(db) }
            }
            db = nil
        }
    }
    private static func prepareDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var directory = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }
    private static func removeFiles(_ url: URL) {
        for path in [url.path, url.path + "-wal", url.path + "-shm"] { try? FileManager.default.removeItem(atPath: path) }
    }
    private static func isSQLite(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 16) == signature
    }
    private static func normalize(_ input: ShumDatabase, ownerID: String) throws -> ShumDatabase {
        var state = input
        guard state.version == 1, state.ownerID == ownerID else { throw ShumFailure.unavailableIdentity }
        if state.invitationStates == nil {
            state.invitationStates = Dictionary(uniqueKeysWithValues: state.contacts.map {
                ($0.id, ShumInvitationState(phase: .accepted, updatedAt: Int64($0.addedAt.timeIntervalSince1970 * 1000), eventID: "legacy-" + $0.id))
            })
        }
        if state.invitationOutbox == nil { state.invitationOutbox = [] }
        state.savedProfiles = nil
        return state
    }
    static func snapshot(at url: URL, key: SymmetricKey) throws -> ShumDatabase {
        if try !isSQLite(url) {
            let data = try Data(contentsOf: url)
            guard data.count <= 100_000_000 else { throw ShumFailure.storage }
            return try JSONDecoder().decode(ShumDatabase.self, from: ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key))
        }
        // The encrypted root gives the owner; opening with it still verifies
        // every row before this snapshot can become a portable backup.
        var connection: OpaquePointer?
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { throw ShumFailure.storage }
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, "SELECT payload FROM records WHERE bucket='header' AND id='root'", -1, &statement, nil) == SQLITE_OK else { throw ShumFailure.storage }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw ShumFailure.storage }
        let encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: encrypted), using: key, authenticating: Row(bucket: "header", id: "root", position: 0).aad)
        let header = try JSONDecoder().decode(Header.self, from: Self.unpack(plain).1)
        return try ShumSQLitePersistence(ownerID: header.state.ownerID, key: key, url: url).read()
    }
    private func indexID(bucket: String, id: String) -> String {
        if bucket == "header" { return id }
        let bytes = HMAC<SHA256>.authenticationCode(for: Data((bucket + "\0" + id).utf8), using: key)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
    private static func pack(id: String, payload: Data) throws -> Data {
        let name = Data(id.utf8)
        guard !name.isEmpty, name.count <= 65_535 else { throw ShumFailure.storage }
        var bytes = Data([UInt8(name.count >> 8), UInt8(name.count & 255)])
        bytes.append(name); bytes.append(payload)
        return bytes
    }
    private static func unpack(_ bytes: Data) throws -> (String, Data) {
        guard bytes.count >= 3 else { throw ShumFailure.storage }
        let length = Int(bytes[bytes.startIndex]) * 256 + Int(bytes[bytes.startIndex + 1])
        guard length > 0, length + 2 < bytes.count,
              let id = String(data: bytes.subdata(in: 2..<2 + length), encoding: .utf8) else { throw ShumFailure.storage }
        return (id, bytes.subdata(in: 2 + length..<bytes.count))
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ShumFailure.storage }
    }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw ShumFailure.storage }
        return result
    }
    private func readHeader() throws -> Header {
        let query = try statement("SELECT payload FROM records WHERE bucket='header' AND id='root' AND position=0")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW, let bytes = sqlite3_column_blob(query, 0) else { throw ShumFailure.storage }
        let encrypted = Data(bytes: bytes, count: Int(sqlite3_column_bytes(query, 0)))
        let plain = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: encrypted), using: key, authenticating: Row(bucket: "header", id: "root", position: 0).aad)
        return try JSONDecoder().decode(Header.self, from: Self.unpack(plain).1)
    }
    func read() throws -> ShumDatabase {
        try queue.sync {
            let stored = try readOnQueue()
            let normalized = try Self.normalize(stored, ownerID: ownerID)
            if stored != normalized { try commitOnQueue(previous: stored, next: normalized) }
            return normalized
        }
    }
    private func readOnQueue() throws -> ShumDatabase {
        try execute("BEGIN DEFERRED")
        defer { try? execute("ROLLBACK") }
        let header = try readHeader()
        var state = header.state
        var groups: [String: [Row]] = [:]
        var readSizes: [String: Int] = [:]
        var readPositions: [String: Int] = [:]
        let query = try statement("SELECT bucket,id,position,payload FROM records ORDER BY bucket,position")
        defer { sqlite3_finalize(query) }
        var rc = sqlite3_step(query)
        while rc == SQLITE_ROW {
            guard let bucket = sqlite3_column_text(query, 0), let id = sqlite3_column_text(query, 1), let bytes = sqlite3_column_blob(query, 3) else { throw ShumFailure.storage }
            var row = Row(bucket: String(cString: bucket), id: String(cString: id), position: Int(sqlite3_column_int64(query, 2)))
            let size = Int(sqlite3_column_bytes(query, 3))
            guard size > 28, size <= 100_000_000 else { throw ShumFailure.storage }
            let encrypted = Data(bytes: bytes, count: size)
            row.indexID = row.id
            let opened = try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: encrypted), using: key, authenticating: row.aad)
            let decoded = try Self.unpack(opened)
            guard indexID(bucket: row.bucket, id: decoded.0) == row.indexID else { throw ShumFailure.storage }
            row.id = decoded.0; row.payload = decoded.1
            readSizes[row.token] = size
            readPositions[row.token] = row.position
            if row.bucket != "header" { groups[row.bucket, default: []].append(row) }
            rc = sqlite3_step(query)
        }
        guard rc == SQLITE_DONE else { throw ShumFailure.storage }
        guard groups.keys.allSatisfy({ header.counts[$0] != nil }), header.counts.allSatisfy({ (groups[$0.key]?.count ?? 0) == $0.value }) else { throw ShumFailure.storage }
        func array<T: Decodable>(_ name: String, _: T.Type) throws -> [T] {
            let rows = groups[name] ?? []
            var previousPosition = -1
            return try rows.map { row in
                guard row.position > previousPosition, let payload = row.payload else { throw ShumFailure.storage }
                previousPosition = row.position
                return try JSONDecoder().decode(T.self, from: payload)
            }
        }
        func dictionary<T: Decodable>(_ name: String, _: T.Type) throws -> [String: T] {
            var values: [String: T] = [:]
            for row in groups[name] ?? [] {
                guard row.position == 0, let payload = row.payload else { throw ShumFailure.storage }
                values[row.id] = try JSONDecoder().decode(T.self, from: payload)
            }
            return values
        }
        state.contacts = try array("contacts", ShumContact.self)
        state.requests = try array("requests", ShumContactCard.self)
        state.conversations = try array("conversations", ShumConversation.self)
        state.messages = try array("messages", ShumStoredMessage.self)
        state.relay = try array("relay", ShumRelayCopy.self)
        state.receipts = try array("receipts", ShumStoredReceipt.self)
        if state.encounters != nil { state.encounters = try array("encounters", ShumEncounter.self) }
        if state.savedProfiles != nil { state.savedProfiles = try array("savedProfiles", ShumSavedProfile.self) }
        if state.invitationOutbox != nil { state.invitationOutbox = try array("invitationOutbox", ShumStoredInvitationControl.self) }
        if state.profileOutbox != nil { state.profileOutbox = try array("profileOutbox", ShumProfileDelivery.self) }
        if state.retractOutbox != nil { state.retractOutbox = try array("retractOutbox", ShumStoredRetract.self) }
        if state.reactionOutbox != nil { state.reactionOutbox = try array("reactionOutbox", ShumStoredReaction.self) }
        state.seenRelay = try dictionary("seenRelay", Date.self)
        if state.blocked != nil { state.blocked = try dictionary("blocked", ShumContactCard.self) }
        if state.deletedMessageIDs != nil { state.deletedMessageIDs = try dictionary("deletedMessageIDs", Date.self) }
        if state.invitationStates != nil { state.invitationStates = try dictionary("invitationStates", ShumInvitationState.self) }
        if state.reactions != nil { state.reactions = try dictionary("reactions", [String: ShumReactionMark].self) }
        if state.legacyHistory != nil { state.legacyHistory?.messages = try array("legacyMessages", ShumLegacyMessage.self) }
        positions = readPositions
        sizes = readSizes; totalBytes = readSizes.values.reduce(0, +)
        guard totalBytes <= 100_000_000 else { throw ShumFailure.storage }
        return state
    }
    private static func header(_ input: ShumDatabase) -> Header {
        var state = input
        var counts: [String: Int] = [:]
        counts["contacts"] = state.contacts.count
        state.contacts = []
        counts["requests"] = state.requests.count
        state.requests = []
        counts["conversations"] = state.conversations.count
        state.conversations = []
        counts["messages"] = state.messages.count
        state.messages = []
        counts["relay"] = state.relay.count
        state.relay = []
        counts["receipts"] = state.receipts.count
        state.receipts = []
        counts["encounters"] = state.encounters?.count ?? 0
        state.encounters = state.encounters == nil ? nil : []
        counts["savedProfiles"] = state.savedProfiles?.count ?? 0
        state.savedProfiles = state.savedProfiles == nil ? nil : []
        counts["invitationOutbox"] = state.invitationOutbox?.count ?? 0
        state.invitationOutbox = state.invitationOutbox == nil ? nil : []
        counts["profileOutbox"] = state.profileOutbox?.count ?? 0
        state.profileOutbox = state.profileOutbox == nil ? nil : []
        counts["retractOutbox"] = state.retractOutbox?.count ?? 0
        state.retractOutbox = state.retractOutbox == nil ? nil : []
        counts["reactionOutbox"] = state.reactionOutbox?.count ?? 0
        state.reactionOutbox = state.reactionOutbox == nil ? nil : []
        counts["seenRelay"] = state.seenRelay.count
        state.seenRelay = [:]
        counts["blocked"] = state.blocked?.count ?? 0
        state.blocked = state.blocked == nil ? nil : [:]
        counts["deletedMessageIDs"] = state.deletedMessageIDs?.count ?? 0
        state.deletedMessageIDs = state.deletedMessageIDs == nil ? nil : [:]
        counts["invitationStates"] = state.invitationStates?.count ?? 0
        state.invitationStates = state.invitationStates == nil ? nil : [:]
        counts["reactions"] = state.reactions?.count ?? 0
        state.reactions = state.reactions == nil ? nil : [:]
        counts["legacyMessages"] = state.legacyHistory?.messages.count ?? 0
        state.legacyHistory?.messages = []
        return Header(state: state, counts: counts)
    }
    func commit(previous: ShumDatabase, next: ShumDatabase) throws {
        try queue.sync { try commitOnQueue(previous: previous, next: next) }
    }
    private func commitOnQueue(previous: ShumDatabase, next: ShumDatabase) throws {
        guard next.ownerID == ownerID, next.version == 1 else { throw ShumFailure.unavailableIdentity }
        var changes: [Row] = []
        func arrays<T: Encodable & Equatable>(_ name: String, _ old: [T], _ new: [T], key: (T) -> String) throws {
            guard old != new else { return }
            // The usual operations update rows in place or append messages.
            // Preserve their ordinals without allocating an index of history.
            if new.count >= old.count, old.indices.allSatisfy({ key(old[$0]) == key(new[$0]) }) {
                for index in old.indices where old[index] != new[index] {
                    let id = key(new[index])
                    changes.append(Row(bucket: name, id: id,
                        position: positions[name + "\0" + id] ?? index,
                        payload: try ShumCoding.encode(new[index])))
                }
                var lastPosition = old.last.map { positions[name + "\0" + key($0)] ?? (old.count - 1) } ?? -1
                var appendedIDs = Set<String>()
                for value in new.dropFirst(old.count) {
                    let id = key(value)
                    guard positions[name + "\0" + id] == nil, appendedIDs.insert(id).inserted else { throw ShumFailure.storage }
                    lastPosition += 1
                    changes.append(Row(bucket: name, id: id, position: lastPosition, payload: try ShumCoding.encode(value)))
                }
                return
            }
            var oldValues: [String: (Int, T)] = [:]
            for (index, value) in old.enumerated() {
                guard oldValues.updateValue((index, value), forKey: key(value)) == nil else { throw ShumFailure.storage }
            }
            // Deleting a row preserves the ordinals of all survivors. A
            // removal must not re-encrypt the rest of a long conversation.
            var lastExisting = -1
            var sawNew = false
            var reorders = false
            for value in new {
                let id = key(value)
                if oldValues[id] != nil {
                    let position = positions[name + "\0" + id] ?? oldValues[id]!.0
                    if sawNew || position <= lastExisting { reorders = true }
                    lastExisting = position
                } else { sawNew = true }
            }
            var lastPosition = -1
            var ids = Set<String>()
            for (index, value) in new.enumerated() {
                let id = key(value)
                guard ids.insert(id).inserted else { throw ShumFailure.storage }
                let position: Int
                if reorders { position = index }
                else if let old = oldValues[id] { position = positions[name + "\0" + id] ?? old.0 }
                else { position = lastPosition + 1 }
                lastPosition = position
                if let cached = oldValues[id], (positions[name + "\0" + id] ?? cached.0) == position, cached.1 == value { continue }
                changes.append(Row(bucket: name, id: id, position: position, payload: try ShumCoding.encode(value)))
            }
            for id in oldValues.keys where !ids.contains(id) { changes.append(Row(bucket: name, id: id, position: 0, payload: nil)) }
        }
        func dictionaries<T: Encodable & Equatable>(_ name: String, _ old: [String: T], _ new: [String: T]) throws {
            guard old != new else { return }
            for (id, value) in new where old[id] != value { changes.append(Row(bucket: name, id: id, position: 0, payload: try ShumCoding.encode(value))) }
            for id in old.keys where new[id] == nil { changes.append(Row(bucket: name, id: id, position: 0, payload: nil)) }
        }
        try arrays("contacts", previous.contacts, next.contacts, key: { $0.id })
        try arrays("requests", previous.requests, next.requests, key: { $0.id })
        try arrays("conversations", previous.conversations, next.conversations, key: { $0.id })
        try arrays("messages", previous.messages, next.messages, key: { $0.id })
        try arrays("relay", previous.relay, next.relay, key: { $0.envelope.id })
        try arrays("receipts", previous.receipts, next.receipts, key: { $0.receipt.key })
        try arrays("encounters", previous.encounters ?? [], next.encounters ?? [], key: { $0.id })
        try arrays("savedProfiles", previous.savedProfiles ?? [], next.savedProfiles ?? [], key: { $0.id })
        try arrays("invitationOutbox", previous.invitationOutbox ?? [], next.invitationOutbox ?? [], key: { $0.id })
        try arrays("profileOutbox", previous.profileOutbox ?? [], next.profileOutbox ?? [], key: { $0.recipientID })
        try arrays("retractOutbox", previous.retractOutbox ?? [], next.retractOutbox ?? [], key: { $0.id })
        try arrays("reactionOutbox", previous.reactionOutbox ?? [], next.reactionOutbox ?? [], key: { $0.id })
        try dictionaries("seenRelay", previous.seenRelay, next.seenRelay)
        try dictionaries("blocked", previous.blocked ?? [:], next.blocked ?? [:])
        try dictionaries("deletedMessageIDs", previous.deletedMessageIDs ?? [:], next.deletedMessageIDs ?? [:])
        try dictionaries("invitationStates", previous.invitationStates ?? [:], next.invitationStates ?? [:])
        try dictionaries("reactions", previous.reactions ?? [:], next.reactions ?? [:])
        try arrays("legacyMessages", previous.legacyHistory?.messages ?? [], next.legacyHistory?.messages ?? [], key: { $0.id })
        let root = Self.header(next)
        if !headerExists || Self.header(previous) != root {
            changes.append(Row(bucket: "header", id: "root", position: 0, payload: try ShumCoding.encode(root)))
        }
        guard !changes.isEmpty else { return }
        var newTotal = totalBytes
        for index in changes.indices {
            var row = changes[index]
            row.indexID = indexID(bucket: row.bucket, id: row.id)
            if let payload = row.payload {
                row.payload = try ChaChaPoly.seal(Self.pack(id: row.id, payload: payload), using: key, authenticating: row.aad).combined
            }
            newTotal -= sizes[row.token] ?? 0
            if let payload = row.payload { newTotal += payload.count }
            changes[index] = row
        }
        guard newTotal <= 100_000_000 else { throw ShumFailure.quota }
        try writerQueue.sync {
            try execute("BEGIN IMMEDIATE")
            do {
                let upsert = try statement("INSERT INTO records(bucket,id,position,payload) VALUES(?,?,?,?) ON CONFLICT(bucket,id) DO UPDATE SET position=excluded.position,payload=excluded.payload")
                defer { sqlite3_finalize(upsert) }
                let delete = try statement("DELETE FROM records WHERE bucket=? AND id=?")
                defer { sqlite3_finalize(delete) }
                for row in changes {
                    let query = row.payload == nil ? delete : upsert
                    sqlite3_reset(query); sqlite3_clear_bindings(query)
                    guard sqlite3_bind_text(query, 1, row.bucket, -1, Self.transient) == SQLITE_OK,
                          sqlite3_bind_text(query, 2, row.indexID ?? row.id, -1, Self.transient) == SQLITE_OK else { throw ShumFailure.storage }
                    if let payload = row.payload {
                        guard sqlite3_bind_int64(query, 3, Int64(row.position)) == SQLITE_OK else { throw ShumFailure.storage }
                        let rc = payload.withUnsafeBytes { sqlite3_bind_blob(query, 4, $0.baseAddress, Int32($0.count), Self.transient) }
                        guard rc == SQLITE_OK else { throw ShumFailure.storage }
                    }
                    guard sqlite3_step(query) == SQLITE_DONE else { throw ShumFailure.storage }
                }
                try execute("COMMIT")
                totalBytes = newTotal; headerExists = true
                for row in changes {
                    if let payload = row.payload {
                        sizes[row.token] = payload.count
                        positions[row.token] = row.position
                    } else {
                        sizes.removeValue(forKey: row.token)
                        positions.removeValue(forKey: row.token)
                    }
                }
                committedCount += 1
                writtenRows += changes.count
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }
}
