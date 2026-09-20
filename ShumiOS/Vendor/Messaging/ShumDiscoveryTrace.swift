import Foundation

/// Temporary, bounded development trace: stages and timing only, no payloads,
/// profile names, identifiers, keys or messages. Compiled out in Release.
enum ShumDiscoveryTrace {
    #if DEBUG
    private static let queue = DispatchQueue(label: "shum.discovery.trace")
    private static var rows: [[String: Any]] = []
    private static var last: [String: Date] = [:]
    #endif

    static func record(_ stage: String) {
        #if DEBUG
        let date = Date()
        queue.async {
            guard date.timeIntervalSince(last[stage] ?? .distantPast) >= 0.25 else { return }
            last[stage] = date
            rows.append(["stage": stage, "time": date.timeIntervalSince1970])
            if rows.count > 300 { rows.removeFirst(rows.count - 300) }
            guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
            try? data.write(to: root.appendingPathComponent("shum-discovery-trace.json"), options: .atomic)
        }
        #endif
    }
}
