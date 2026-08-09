import Foundation
import SwiftUI

@MainActor
final class PeopleViewModel: ObservableObject {

    @Published private(set) var devices: [String: Int] = [:]
    @Published private(set) var distances: [String: Int] = [:]
    @Published private(set) var userCache: [String: NearbyUser] = [:]

    private var distanceTimer: Timer?
    private var loadingUserIDs: Set<String> = []

    private static let validIDPattern = #"^\d+$"#

    init() {
        BLEManager.shared.delegate = self
        startDistanceUpdater()
    }

    deinit {
        distanceTimer?.invalidate()
    }

    func loadUserIfNeeded(tgID: String) async {
        guard userCache[tgID] == nil else {
            return
        }

        await refreshUser(tgID: tgID)
    }

    func refreshUser(tgID: String) async {
        guard let numericTGID = Int(tgID) else {
            print("Invalid Telegram ID: \(tgID)")
            return
        }

        guard !loadingUserIDs.contains(tgID) else {
            return
        }

        loadingUserIDs.insert(tgID)

        defer {
            loadingUserIDs.remove(tgID)
        }

        do {
            let data = try await FetchService.fetch
                .fetchUserDataByTGID(for: numericTGID)

            guard devices[tgID] != nil else {
                return
            }

            userCache[tgID] = NearbyUser(
                id: tgID,
                tgName: data.tgName,
                tgUsername: data.tgUsername,
                photoURL: data.photoS3URL
            )
        } catch {
            print(
                "Failed to refresh user \(tgID): \(error.localizedDescription)"
            )
        }
    }

    func refreshVisibleUsers() async {
        let visibleIDs = Array(devices.keys)

        for id in visibleIDs {
            await refreshUser(tgID: id)
        }
    }

    func toggleScanning(_ enabled: Bool) {
        if enabled {
            BLEManager.shared.startScanning()
        } else {
            BLEManager.shared.stopScanning()
            clearDevices()
        }
    }

    func startAdvertising(tgID: String) {
        guard isValidTelegramID(tgID) else {
            print("Cannot advertise invalid Telegram ID: \(tgID)")
            return
        }

        BLEManager.shared.startAdvertising(id: tgID)
    }

    func restartAdvertising(tgID: String) {
        guard isValidTelegramID(tgID) else {
            print("Cannot advertise invalid Telegram ID: \(tgID)")
            return
        }

        BLEManager.shared.restartAdvertising(id: tgID)
    }

    func stopAdvertising() {
        BLEManager.shared.stopAdvertising()
    }

    func stopAllBluetoothActivity() {
        BLEManager.shared.stopScanning()
        BLEManager.shared.stopAdvertising()
        clearDevices()
    }

    private func startDistanceUpdater() {
        distanceTimer?.invalidate()

        distanceTimer = Timer.scheduledTimer(
            withTimeInterval: 5,
            repeats: true
        ) { [weak self] _ in
            guard let self else {
                return
            }

            Task { @MainActor in
                self.recalculateDistances()
            }
        }
    }

    private func recalculateDistances() {
        var updatedDistances: [String: Int] = [:]

        for (id, rssi) in devices {
            updatedDistances[id] = distanceFromRSSI(rssi)
        }

        distances = updatedDistances
    }

    func distanceFromRSSI(
        _ rssi: Int,
        txPower: Int = -59,
        pathLossExponent: Double = 2
    ) -> Int {
        guard rssi < 0 else {
            return 1
        }

        let exponent = Double(txPower - rssi)
            / (10.0 * pathLossExponent)

        let distance = pow(10.0, exponent)

        return max(1, Int(distance.rounded()))
    }

    func clearDevices() {
        devices.removeAll()
        distances.removeAll()
        userCache.removeAll()
    }

    private func isValidTelegramID(_ id: String) -> Bool {
        id.range(
            of: Self.validIDPattern,
            options: .regularExpression
        ) != nil
    }

    private func receiveDevice(
        id: String,
        rssi: Int
    ) {
        guard isValidTelegramID(id) else {
            print("Ignored invalid BLE identity: \(id)")
            return
        }

        devices[id] = rssi
        distances[id] = distanceFromRSSI(rssi)
    }
}

extension PeopleViewModel: BLEManagerDelegate {

    nonisolated func didDiscoverDevice(
        id: String,
        rssi: Int
    ) {
        Task { @MainActor [weak self] in
            self?.receiveDevice(
                id: id,
                rssi: rssi
            )
        }
    }

    nonisolated func didUpdateDevice(
        id: String,
        rssi: Int
    ) {
        Task { @MainActor [weak self] in
            self?.receiveDevice(
                id: id,
                rssi: rssi
            )
        }
    }

    nonisolated func didLoseDevice(id: String) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            devices.removeValue(forKey: id)
            distances.removeValue(forKey: id)
            userCache.removeValue(forKey: id)
        }
    }

    nonisolated func didFail(with error: Error) {
        print("BLE error: \(error.localizedDescription)")
    }
}
