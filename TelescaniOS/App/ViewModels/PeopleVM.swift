import Foundation
import SwiftUI

@MainActor
final class PeopleViewModel: ObservableObject {
    @Published private(set) var devices: [String: Int] = [:]
    @Published private(set) var distances: [String: Int] = [:]
    @Published private(set) var userCache: [String: NearbyUser] = [:]

    private var distanceTimer: Timer?
    private var rssiSamples: [String: [Int]] = [:]
    private var loadingUserIDs: Set<String> = []
    private let distanceUpdateInterval: TimeInterval = 3
    private let maximumRSSISamples = 30

    init() {
        BLEManager.shared.delegate = self
        startDistanceUpdater()
    }

    deinit { distanceTimer?.invalidate() }

    func loadUserIfNeeded(telescanID: String) async {
        guard userCache[telescanID] == nil else { return }
        await refreshUser(telescanID: telescanID)
    }

    func refreshUser(telescanID: String) async {
        guard let id = UUID(uuidString: telescanID),
              !loadingUserIDs.contains(telescanID) else { return }
        loadingUserIDs.insert(telescanID)
        defer { loadingUserIDs.remove(telescanID) }
        guard let data = try? await FetchService.fetch.profile(telescanID: id),
              devices[telescanID] != nil else { return }
        userCache[telescanID] = NearbyUser(
            id: data.telescanId,
            name: data.name,
            username: data.username.map { $0.hasPrefix("@") ? $0 : "@" + $0 },
            photoURL: data.photoUrl
        )
    }

    func refreshVisibleUsers() async {
        for id in Array(devices.keys) {
            await refreshUser(telescanID: id)
        }
    }

    func refreshNearbyPeople() async {
        BLEManager.shared.stopScanning()
        BLEManager.shared.startScanning()
        await refreshVisibleUsers()
    }

    func toggleScanning(_ enabled: Bool) {
        if enabled {
            BLEManager.shared.startScanning()
        } else {
            BLEManager.shared.stopScanning()
            clearDevices()
        }
    }

    func startAdvertising(telescanID: UUID) {
        BLEManager.shared.startAdvertising(id: telescanID.uuidString.lowercased())
    }

    func restartAdvertising(telescanID: UUID) {
        BLEManager.shared.restartAdvertising(id: telescanID.uuidString.lowercased())
    }

    func stopAdvertising() { BLEManager.shared.stopAdvertising() }

    func stopAllBluetoothActivity() {
        BLEManager.shared.stopScanning()
        BLEManager.shared.stopAdvertising()
        clearDevices()
    }

    private func startDistanceUpdater() {
        distanceTimer?.invalidate()
        let timer = Timer(timeInterval: distanceUpdateInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.recalculateDistances() }
        }
        RunLoop.main.add(timer, forMode: .common)
        distanceTimer = timer
    }

    private func recalculateDistances() {
        var updated: [String: Int] = [:]
        for (id, rssi) in devices {
            let samples = rssiSamples[id] ?? [rssi]
            let sorted = samples.sorted()
            updated[id] = distanceFromRSSI(sorted[sorted.count / 2])
        }
        distances = updated
        rssiSamples.removeAll(keepingCapacity: true)
    }

    func distanceFromRSSI(
        _ rssi: Int,
        txPower: Int = -59,
        pathLossExponent: Double = 2
    ) -> Int {
        guard rssi < 0 else { return 1 }
        let exponent = Double(txPower - rssi) / (10 * pathLossExponent)
        return max(1, Int(pow(10, exponent).rounded()))
    }

    func clearDevices() {
        devices.removeAll()
        distances.removeAll()
        userCache.removeAll()
        rssiSamples.removeAll()
    }

    private func receiveDevice(id: String, rssi: Int) {
        guard UUID(uuidString: id) != nil else { return }
        let isNew = devices[id] == nil
        devices[id] = rssi
        rssiSamples[id, default: []].append(rssi)
        if rssiSamples[id, default: []].count > maximumRSSISamples {
            rssiSamples[id]?.removeFirst()
        }
        if isNew { distances[id] = distanceFromRSSI(rssi) }
    }
}

extension PeopleViewModel: BLEManagerDelegate {
    nonisolated func didDiscoverDevice(id: String, rssi: Int) {
        Task { @MainActor [weak self] in self?.receiveDevice(id: id, rssi: rssi) }
    }

    nonisolated func didUpdateDevice(id: String, rssi: Int) {
        Task { @MainActor [weak self] in self?.receiveDevice(id: id, rssi: rssi) }
    }

    nonisolated func didLoseDevice(id: String) {
        Task { @MainActor [weak self] in
            self?.devices.removeValue(forKey: id)
            self?.distances.removeValue(forKey: id)
            self?.userCache.removeValue(forKey: id)
            self?.rssiSamples.removeValue(forKey: id)
        }
    }

    nonisolated func didFail(with error: Error) { }
}
