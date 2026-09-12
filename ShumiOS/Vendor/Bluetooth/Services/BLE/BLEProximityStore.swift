import BitFoundation
import Foundation

/// Local signal measurements only. Bindings are supplied by the existing BLE
/// identity flow; relayed traffic never becomes a distance measurement.
final class BLEProximityStore: @unchecked Sendable {
    private struct Sample {
        let rssi: Int
        let date: Date
    }

    private let lock = NSLock()
    private var samples: [String: [Sample]] = [:]
    private var bindings: [String: PeerID] = [:]
    private let lifetime: TimeInterval = 30

    func record(_ rssi: Int, peripheralID: String, at date: Date = Date()) {
        // CoreBluetooth uses 127 when a signal measurement is unavailable.
        guard (-127 ... -1).contains(rssi) else { return }
        lock.withLock {
            samples = samples.filter { _, values in
                values.last.map { date.timeIntervalSince($0.date) < lifetime } ?? false
            }
            var values = samples[peripheralID, default: []].filter {
                date.timeIntervalSince($0.date) < lifetime
            }
            values.append(Sample(rssi: rssi, date: date))
            samples[peripheralID] = Array(values.suffix(30))
            if samples.count > 256,
               let oldest = samples.min(by: { ($0.value.last?.date ?? .distantPast) < ($1.value.last?.date ?? .distantPast) })?.key {
                samples.removeValue(forKey: oldest)
            }
        }
    }

    func bind(_ peripheralID: String, to peer: PeerID) {
        lock.withLock { bindings[peripheralID] = peer }
    }

    func remove(_ peripheralID: String) {
        lock.withLock {
            bindings.removeValue(forKey: peripheralID)
            samples.removeValue(forKey: peripheralID)
        }
    }

    func reset() {
        lock.withLock {
            bindings.removeAll()
            samples.removeAll()
        }
    }

    func distanceMeters(for peer: PeerID, at date: Date = Date()) -> Int? {
        lock.withLock {
            let readings = bindings.filter { $0.value == peer }.keys.flatMap {
                samples[$0, default: []]
            }.filter {
                let age = date.timeIntervalSince($0.date)
                return age >= 0 && age < lifetime
            }.map(\.rssi).sorted()
            guard !readings.isEmpty else { return nil }
            // Telescan's median RSSI estimate: -59 dBm at one metre, n = 2.
            let median = readings[readings.count / 2]
            return max(1, Int(pow(10, Double(-59 - median) / 20).rounded()))
        }
    }
}
