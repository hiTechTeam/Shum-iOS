import Foundation

/// Nostr events this device has already handled, kept on disk for as long as
/// relays may send them again. Without it every launch replays the whole fetch
/// window: each old message is opened, acknowledged and saved once more, and
/// the app stalls until the backlog is through.
@MainActor
final class ShumHandledEvents {
    /// The fetch window is three days; one more day covers shifted timestamps.
    static let lifetime: TimeInterval = 4 * 86_400
    static let limit = 30_000
    /// A record is the 32-byte event ID followed by the time it was handled.
    private static let recordSize = 36
    private static let queue = DispatchQueue(label: "shum.handled-events", qos: .utility)

    private let url: URL?
    private let now: () -> Date
    private var handled: [Data: UInt32] = [:]
    private var saveScheduled = false

    init(url: URL?, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        guard let url, let data = try? Data(contentsOf: url),
              data.count % Self.recordSize == 0 else { return }
        let oldest = Self.seconds(now().addingTimeInterval(-Self.lifetime))
        var offset = data.startIndex
        while offset < data.endIndex {
            let id = Data(data[offset..<offset + 32])
            let time = data[offset + 32..<offset + Self.recordSize].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if time >= oldest { handled[id] = time }
            offset += Self.recordSize
        }
    }

    static var liveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShumConversations/nostr-handled.bin")
    }

    var count: Int { handled.count }

    func contains(_ eventID: String) -> Bool {
        guard let key = Self.key(eventID) else { return false }
        return handled[key] != nil
    }

    func insert(_ eventID: String) {
        guard let key = Self.key(eventID), handled[key] == nil else { return }
        handled[key] = Self.seconds(now())
        if handled.count > Self.limit + 1_000 { trim() }
        scheduleSave()
    }

    /// Writes the list now; the app calls it before going to the background.
    func save(synchronously: Bool = false) {
        guard let url else { return }
        var data = Data(capacity: handled.count * Self.recordSize)
        for (id, time) in handled {
            data.append(id)
            withUnsafeBytes(of: time.bigEndian) { data.append(contentsOf: $0) }
        }
        let bytes = data
        let write: @Sendable () -> Void = {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            #if os(iOS)
            try? bytes.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try? bytes.write(to: url, options: .atomic)
            #endif
        }
        if synchronously { Self.queue.sync(execute: write) } else { Self.queue.async(execute: write) }
    }

    /// A burst of events is written once, a moment after it ends, off the main thread.
    private func scheduleSave() {
        guard url != nil, !saveScheduled else { return }
        saveScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.saveScheduled = false
            self.save()
        }
    }

    private func trim() {
        let newest = handled.sorted { $0.value > $1.value }.prefix(Self.limit)
        handled = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
    }

    private static func seconds(_ date: Date) -> UInt32 {
        UInt32(clamping: Int64(max(0, date.timeIntervalSince1970)))
    }

    /// Nostr event IDs are 64 hexadecimal characters.
    private static func key(_ eventID: String) -> Data? {
        let bytes = Array(eventID.utf8)
        guard bytes.count == 64 else { return nil }
        var data = Data(capacity: 32)
        var index = 0
        while index < 64 {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            data.append(high << 4 | low)
            index += 2
        }
        return data
    }

    private static func nibble(_ character: UInt8) -> UInt8? {
        switch character {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): character - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): character - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): character - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
