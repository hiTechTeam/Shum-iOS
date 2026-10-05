#if SHUM_LOAD_TESTS
import BitFoundation
import CoreBluetooth
import CryptoKit
import Foundation
import QuartzCore
import SQLite3
import SwiftUI
import Testing
@preconcurrency @testable import Shum

/// Opt-in device benchmark. Build Release with ENABLE_TESTABILITY=YES and
/// SHUM_LOAD_TESTS; use a separate host bundle identifier to isolate user data.
/// Timings are observations, not pass assertions. Integrity checks must pass.
@Suite("Encrypted storage load", .serialized)
@MainActor
struct ShumStorageLoadTests {
    @MainActor private final class Internet: ShumInternetTransport {
        var received: ((ShumPacket, String) -> Void)?
        var connected = true
        func start() {}
        func stop() {}
        func send(_ packet: ShumPacket, to card: ShumContactCard, completion: @escaping (Bool) -> Void) {
            completion(true)
        }
        func resolve(_ locator: ShumContactLocator, completion: @escaping (Result<ShumResolvedContact, Error>) -> Void) {
            completion(.failure(ShumFailure.contactUnavailable))
        }
        func configureContactLookup(card: @escaping () -> ShumContactCard?, profile: @escaping () -> ShumProfile?) {}
    }

    private func record(_ count: Int, _ operation: String, _ milliseconds: [Double], bytes: Int = 0) {
        let sorted = milliseconds.sorted()
        let data: [String: Any] = ["messages": count, "operation": operation,
            "samples": milliseconds, "median_ms": sorted[sorted.count / 2],
            "p95_ms": sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))],
            "max_ms": sorted.last!, "database_bytes": bytes,
            "device": UIDevice.current.model, "os": UIDevice.current.systemVersion, "sqlite_version": String(cString: sqlite3_libversion())]
        let json = try! JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
        print("SHUM_LOAD_METRIC " + String(decoding: json, as: UTF8.self))
    }

    /// A queued main-thread callback also measures how long UI work must wait
    /// behind this synchronous operation. It excludes fixture preparation.
    private func measure(_ body: () throws -> Void) async throws -> (operation: Double, mainQueue: Double) {
        let queued = CACurrentMediaTime()
        let lag = Task { @MainActor in (CACurrentMediaTime() - queued) * 1000 }
        let start = CACurrentMediaTime()
        do { try body() } catch { _ = await lag.value; throw error }
        let elapsed = (CACurrentMediaTime() - start) * 1000
        return (elapsed, await lag.value)
    }

    private func envelope(index: Int, from sender: ShumPermanentTests.Node,
                          to recipient: ShumPermanentTests.Node, clock: ShumPermanentTests.Clock) throws -> (ShumEnvelope, String) {
        let id = UUID().uuidString
        let timestamp = Int64(clock.date.timeIntervalSince1970 * 1000) - Int64(index % 50_000)
        let text = "Сообщение \(index). " + String(repeating: "Это обычная переписка для проверки скорости хранилища. ", count: 4)
        let conversation = ShumConversation.identifier(sender.card.id, recipient.card.id)
        let plain = ShumPlaintext(id: id, conversationID: conversation, senderID: sender.card.id,
            recipientID: recipient.card.id, timestamp: timestamp, expiresAt: timestamp + 86_400_000, text: text)
        var result = ShumEnvelope(id: id, conversationID: conversation, sender: sender.card,
            recipient: recipient.card, timestamp: timestamp, expiresAt: plain.expiresAt,
            ciphertext: try ShumCryptoService(wire: sender.wire).seal(ShumCoding.encode(plain), to: recipient.card.noiseKey))
        result.signature = try #require(sender.wire.noiseSignData(result.signingBytes()))
        return (result, text)
    }

    @Test(arguments: [1_000, 5_000, 10_000])
    func encryptedHistoryAndIncomingBurst(count: Int) async throws {
        print("SHUM_LOAD_PHASE preparing \(count)")
        let clock = ShumPermanentTests.Clock()
        let a = try ShumPermanentTests.Node("Load Alice", clock: clock)
        let b = try ShumPermanentTests.Node("Load Bob", clock: clock)
        try ShumPermanentTests().allowBoth(a, b, clock: clock)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShumLoad-\(UUID())")
        let url = directory.appendingPathComponent("state.enc")
        defer { try? FileManager.default.removeItem(at: directory) }
        let disk = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        var fixture = a.store.state
        fixture.messages = try (0..<count).map { index in
            let outgoing = index % 2 == 0
            let (packet, text) = try envelope(index: index, from: outgoing ? a : b, to: outgoing ? b : a, clock: clock)
            return ShumStoredMessage(envelope: packet, text: text, outgoing: outgoing,
                status: .delivered, unread: !outgoing && index >= count - 40)
        }
        try disk.transaction { $0 = fixture }
        let bytes = try Data(contentsOf: url).count
        let packets = try (0..<20).map { try envelope(index: count + $0, from: b, to: a, clock: clock).0 }
        let internet = Internet()
        let defaultsName = "ShumLoad.\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        var store: ShumConversationStore!
        var service: ShumMessageStore!
        var runtime: ShumRuntime!
        var loadSamples: [Double] = []
        print("SHUM_LOAD_PHASE measuring \(count) bytes=\(bytes)")
        for _ in 0..<3 {
            let sample = try await measure {
                store = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
            }
            #expect(store.state.messages.count == count)
            loadSamples.append(sample.operation)
        }
        record(count, "restore_decrypt_decode", loadSamples, bytes: bytes)
        // Registered live clients use exactly this preparation path, off the
        // main actor. Raw restore above remains a diagnostic comparison.
        do {
            let pulse = Task { @MainActor () -> [Double] in
                var delays: [Double] = []
                while !Task.isCancelled {
                    let started = CACurrentMediaTime()
                    try? await Task.sleep(for: .milliseconds(10))
                    if !Task.isCancelled { delays.append(max(0, (CACurrentMediaTime() - started) * 1000 - 10)) }
                }
                return delays
            }
            defer { pulse.cancel() }
            let ownerID = a.card.id, key = a.identity.storageKey
            let legacyURL = directory.appendingPathComponent("absent-legacy.enc")
            let start = CACurrentMediaTime()
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ShumConversationStore.prepare(ownerID: ownerID, key: key, url: url, legacyURL: legacyURL, legacyKey: nil)
            }.value
            let elapsed = (CACurrentMediaTime() - start) * 1000
            pulse.cancel()
            let delays = await pulse.value
            #expect(ShumConversationStore(prepared: prepared).state.messages == fixture.messages)
            record(count, "async_history_load_wall_time", [elapsed], bytes: bytes)
            record(count, "async_history_load_main_actor_jitter", delays.isEmpty ? [0] : delays, bytes: bytes)
        }
        // Separate the JSON cost from encryption and the actual durable
        // transaction. Even one metadata change currently writes all history.
        do {
            var encoded = Data()
            let encoding = try await measure { encoded = try ShumCoding.encode(store.state) }
            record(count, "encode_entire_snapshot_json", [encoding.operation], bytes: bytes)
            var encrypted = Data()
            let encryption = try await measure {
                encrypted = try ChaChaPoly.seal(encoded, using: a.identity.storageKey).combined
            }
            #expect(encrypted.count == encoded.count + 28)
            record(count, "encrypt_entire_snapshot", [encryption.operation], bytes: bytes)
        }
        let transaction = try await measure {
            try store.transaction { $0.contacts[0].metadata["loadBenchmark"] = "synthetic" }
        }
        record(count, "persist_one_metadata_change_full_database", [transaction.operation], bytes: bytes)
        let startup = try await measure {
            service = try ShumMessageStore(identity: a.identity, store: store, transport: a.wire,
                wire: a.wire, card: a.card, internet: internet, now: { clock.date })
            runtime = ShumRuntime(transport: a.wire, defaults: defaults, now: { clock.date })
            runtime.didReceiveTransportEvent(.bluetoothStateUpdated(.poweredOn))
            runtime.configurePermanentStore(service)
        }
        #expect(runtime.messages.count == count)
        record(count, "service_init_and_initial_projection", [startup.operation], bytes: bytes)
        var resumes: [Double] = []
        for _ in 0..<5 {
            let sample = try await measure { runtime.setAppActive(false); runtime.setAppActive(true) }
            resumes.append(sample.operation)
        }
        record(count, "background_foreground_idle", resumes, bytes: bytes)
        let open = try await measure { runtime.openConversation(b.card.peerID) }
        #expect(store.state.messages.allSatisfy { !$0.unread })
        record(count, "open_chat_mark_20_read", [open.operation], bytes: bytes)
        let timeline = ShumTimelineController(storageKey: defaultsName + ".timeline")
        defer { UserDefaults.standard.removeObject(forKey: defaultsName + ".timeline") }
        var built = Set<Int>()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = timeline
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let layout = try await measure {
            let messages = runtime.conversation(b.card.peerID)
            timeline.update(items: messages.map { ShumTimelineItem(id: $0.id, revision: 0) },
                appearanceKey: "load", command: nil) { index, width in
                    built.insert(index)
                    return AnyView(Text(messages[index].text).frame(width: width, alignment: .leading).padding(8))
                }
            timeline.view.frame = window.bounds
            timeline.view.setNeedsLayout()
            timeline.view.layoutIfNeeded()
        }
        #expect(built.count < 80)
        record(count, "timeline_text_rows_initial_layout", [layout.operation], bytes: bytes)
        runtime.closeConversation(b.card.peerID)
        var incoming: [Double] = [], lags: [Double] = []
        let burstStart = CACurrentMediaTime()
        for packet in packets {
            let sample = try await measure {
                service.receive(ShumPacket(envelope: packet), from: nil, nostrSender: b.card.nostrKey)
            }
            incoming.append(sample.operation); lags.append(sample.mainQueue)
        }
        #expect(store.state.messages.count == count + packets.count)
        #expect(runtime.messages.count == count + packets.count)
        #expect(packets.allSatisfy { p in store.state.receipts.contains { $0.receipt.envelopeID == p.id } })
        record(count, "incoming_message_crypto_disk_projection", incoming, bytes: bytes)
        record(count, "incoming_main_actor_queue_delay", lags, bytes: bytes)
        record(count, "incoming_burst_20_total", [(CACurrentMediaTime() - burstStart) * 1000], bytes: bytes)
        let acknowledgements = try fixture.messages.filter(\.outgoing).prefix(20).map { message in
            var receipt = ShumReceipt(envelopeID: message.id, digest: message.envelope.digest,
                sender: b.card, destination: a.card, read: true,
                timestamp: Int64(clock.date.timeIntervalSince1970 * 1000),
                expiresAt: Int64(clock.date.timeIntervalSince1970 * 1000) + 86_400_000)
            receipt.signature = try #require(b.wire.noiseSignData(receipt.signingBytes()))
            return receipt
        }
        var ackSamples: [Double] = []
        for receipt in acknowledgements {
            let sample = try await measure {
                service.receive(ShumPacket(receipt: receipt), from: nil, nostrSender: b.card.nostrKey)
            }
            ackSamples.append(sample.operation)
        }
        #expect(acknowledgements.allSatisfy { receipt in
            store.state.messages.first { $0.id == receipt.envelopeID }?.status == .read
        })
        record(count, "outgoing_read_ack_disk_projection", ackSamples, bytes: bytes)
        // These are already decrypted application packets. Nostr's earlier
        // handled-event filter is deliberately bypassed to measure its fallback.
        var duplicateSamples: [Double] = []
        for packet in packets {
            let sample = try await measure {
                service.receive(ShumPacket(envelope: packet), from: nil, nostrSender: b.card.nostrKey)
            }
            duplicateSamples.append(sample.operation)
        }
        #expect(store.state.messages.count == count + packets.count)
        record(count, "duplicate_packet_receipt_fallback", duplicateSamples, bytes: bytes)
        runtime.setAppActive(false)
        runtime.openConversation(b.card.peerID)
        #expect(store.state.messages.filter(\.unread).count == packets.count)
        let readNew = try await measure { runtime.setAppActive(true) }
        #expect(store.state.messages.allSatisfy { !$0.unread })
        record(count, "foreground_with_open_chat_20_unread", [readNew.operation], bytes: bytes)
        let cacheURL = directory.appendingPathComponent("handled.bin")
        let cache = ShumHandledEvents(url: cacheURL)
        let ids = (0..<count).map { ShumContactCard.userID(Data("load-event-\($0)".utf8)) }
        for id in ids { cache.insert(id) }
        cache.save(synchronously: true)
        let restoredCache = ShumHandledEvents(url: cacheURL)
        #expect(restoredCache.count == count)
        let replay = try await measure {
            for id in ids { #expect(restoredCache.contains(id)) }
        }
        record(count, "nostr_handled_cache_skip_all_history", [replay.operation], bytes: bytes)
        restoredCache.insert(ShumContactCard.userID(Data("one-new-event".utf8)))
        let saveCache = try await measure { restoredCache.save() }
        record(count, "handled_cache_async_save_main_thread", [saveCache.operation], bytes: bytes)
        restoredCache.save(synchronously: true)
        let restored = try ShumConversationStore(ownerID: a.card.id, key: a.identity.storageKey, url: url)
        #expect(restored.state.messages.count == count + packets.count)
        #expect(restored.state.messages.allSatisfy { !$0.unread })
        print("SHUM_LOAD_PHASE complete \(count)")
    }
}
#endif
