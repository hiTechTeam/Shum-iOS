import Foundation
import SwiftUI

private enum NearbyProfileError: LocalizedError {
    case incomplete
    case mismatchedIdentity

    var errorDescription: String? {
        switch self {
        case .incomplete:
            return "Nearby profile is incomplete"
        case .mismatchedIdentity:
            return "Nearby profile identity does not match"
        }
    }
}

@MainActor
final class PeopleViewModel: ObservableObject {
    @Published private(set) var devices: [String: Int] = [:]
    @Published private(set) var distances: [String: Int] = [:]
    @Published private(set) var userCache: [String: NearbyUser] = [:]
    @Published private(set) var discoveryError: String?

    var visibleUsers: [NearbyUser] {
        userCache.values.sorted { first, second in
            let firstDistance = distances[first.discoveryID] ?? Int.max
            let secondDistance = distances[second.discoveryID] ?? Int.max
            if firstDistance == secondDistance {
                return first.username.localizedCaseInsensitiveCompare(
                    second.username
                ) == .orderedAscending
            }
            return firstDistance < secondDistance
        }
    }

    private let bleManager: BLEManagerProtocol
    private let profileLoader: @MainActor (UUID) async throws
        -> TelescanProfileResponse
    private var distanceTimer: Timer?
    private var rssiSamples: [String: [Int]] = [:]
    private var profileTasks: [String: Task<Void, Never>] = [:]
    private var resolutionAttempts: [String: Int] = [:]
    private let distanceUpdateInterval: TimeInterval = 3
    private let maximumRSSISamples = 30
    private let maximumRetryDelay: TimeInterval = 30

    init(
        bleManager: BLEManagerProtocol = BLEManager.shared,
        profileLoader: @escaping @MainActor (UUID) async throws
            -> TelescanProfileResponse = {
                try await FetchService.fetch.profile(telescanID: $0)
            }
    ) {
        self.bleManager = bleManager
        self.profileLoader = profileLoader
        bleManager.delegate = self
        startDistanceUpdater()
    }

    deinit {
        distanceTimer?.invalidate()
        for task in profileTasks.values {
            task.cancel()
        }
    }

    func loadUserIfNeeded(telescanID: String) async {
        scheduleProfileResolution(for: telescanID, immediately: true)
        await profileTasks[telescanID]?.value
    }

    func refreshUser(telescanID: String) async {
        guard devices[telescanID] != nil else { return }
        profileTasks[telescanID]?.cancel()
        profileTasks[telescanID] = nil
        resolutionAttempts[telescanID] = 0
        scheduleProfileResolution(
            for: telescanID,
            immediately: true,
            force: true
        )
        await profileTasks[telescanID]?.value
    }

    func refreshVisibleUsers() async {
        let ids = Array(devices.keys)
        for id in ids {
            profileTasks[id]?.cancel()
            profileTasks[id] = nil
            resolutionAttempts[id] = 0
            scheduleProfileResolution(for: id, immediately: true, force: true)
        }
        let tasks = ids.compactMap { profileTasks[$0] }
        for task in tasks {
            await task.value
        }
    }

    func refreshNearbyPeople() async {
        clearDevices()
        bleManager.restartScanning()
    }

    func toggleScanning(_ enabled: Bool) {
        discoveryError = nil
        if enabled {
            bleManager.startScanning()
        } else {
            bleManager.stopScanning()
            clearDevices()
        }
    }

    func startAdvertising(telescanID: UUID) {
        bleManager.startAdvertising(id: telescanID.uuidString.lowercased())
    }

    func restartAdvertising(telescanID: UUID) {
        bleManager.restartAdvertising(id: telescanID.uuidString.lowercased())
    }

    func stopAdvertising() {
        bleManager.stopAdvertising()
    }

    func reconcileBluetoothState(isActive: Bool) {
        bleManager.setApplicationActive(isActive)
        if isActive {
            bleManager.reconcileDiscoveryState()
        }
    }

    func stopAllBluetoothActivity() {
        bleManager.stopScanning()
        bleManager.stopAdvertising()
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
        for task in profileTasks.values {
            task.cancel()
        }
        profileTasks.removeAll()
        resolutionAttempts.removeAll()
        devices.removeAll()
        distances.removeAll()
        userCache.removeAll()
        rssiSamples.removeAll()
    }

    private func receiveDevice(id: String, rssi: Int) {
        guard let uuid = UUID(uuidString: id) else { return }
        let canonicalID = uuid.uuidString.lowercased()
        let isNew = devices[canonicalID] == nil
        devices[canonicalID] = rssi
        rssiSamples[canonicalID, default: []].append(rssi)
        if rssiSamples[canonicalID, default: []].count > maximumRSSISamples {
            rssiSamples[canonicalID]?.removeFirst()
        }
        if isNew {
            distances[canonicalID] = distanceFromRSSI(rssi)
        }
        discoveryError = nil
        scheduleProfileResolution(for: canonicalID, immediately: isNew)
    }

    private func scheduleProfileResolution(
        for id: String,
        immediately: Bool,
        force: Bool = false
    ) {
        guard devices[id] != nil,
              profileTasks[id] == nil,
              force || userCache[id] == nil else {
            return
        }

        let attempt = resolutionAttempts[id, default: 0]
        let delay = immediately
            ? 0
            : min(pow(2, Double(attempt)), maximumRetryDelay)

        profileTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled, self.devices[id] != nil else { return }
            await self.resolveProfile(for: id)
        }
    }

    private func resolveProfile(for id: String) async {
        guard let requestedID = UUID(uuidString: id) else {
            profileTasks[id] = nil
            return
        }

        do {
            let response = try await profileLoader(requestedID)
            try Task.checkCancellation()
            guard devices[id] != nil else {
                profileTasks[id] = nil
                return
            }
            let user = try validatedUser(
                response,
                requestedID: requestedID
            )
            userCache[id] = user
            resolutionAttempts[id] = 0
            profileTasks[id] = nil
        } catch is CancellationError {
            profileTasks[id] = nil
        } catch {
            if error is NearbyProfileError
                || isNotFound(error) {
                userCache.removeValue(forKey: id)
            }
            resolutionAttempts[id, default: 0] += 1
            profileTasks[id] = nil
            guard devices[id] != nil else { return }
            scheduleProfileResolution(for: id, immediately: false, force: true)
        }
    }

    private func validatedUser(
        _ profile: TelescanProfileResponse,
        requestedID: UUID
    ) throws -> NearbyUser {
        guard profile.telescanId == requestedID else {
            throw NearbyProfileError.mismatchedIdentity
        }
        guard let usernameValue = profile.username?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !usernameValue.isEmpty else {
            throw NearbyProfileError.incomplete
        }
        let username = usernameValue.hasPrefix("@")
            ? usernameValue
            : "@" + usernameValue
        let trimmedName = profile.name?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.flatMap { $0.isEmpty ? nil : $0 }
            ?? username
        let photoURL = profile.photoUrl.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, URL(string: trimmed) != nil else { return nil }
            return trimmed
        }
        return NearbyUser(
            id: profile.telescanId,
            name: name,
            username: username,
            photoURL: photoURL
        )
    }

    private func isNotFound(_ error: Error) -> Bool {
        if case APIClientError.httpStatus(let status) = error {
            return status == 404
        }
        return false
    }

    private func loseDevice(id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        let canonicalID = uuid.uuidString.lowercased()
        profileTasks[canonicalID]?.cancel()
        profileTasks.removeValue(forKey: canonicalID)
        resolutionAttempts.removeValue(forKey: canonicalID)
        devices.removeValue(forKey: canonicalID)
        distances.removeValue(forKey: canonicalID)
        userCache.removeValue(forKey: canonicalID)
        rssiSamples.removeValue(forKey: canonicalID)
    }
}

extension PeopleViewModel: BLEManagerDelegate {
    nonisolated func didDiscoverDevice(id: String, rssi: Int) {
        Task { @MainActor [weak self] in
            self?.receiveDevice(id: id, rssi: rssi)
        }
    }

    nonisolated func didUpdateDevice(id: String, rssi: Int) {
        Task { @MainActor [weak self] in
            self?.receiveDevice(id: id, rssi: rssi)
        }
    }

    nonisolated func didLoseDevice(id: String) {
        Task { @MainActor [weak self] in
            self?.loseDevice(id: id)
        }
    }

    nonisolated func didFail(with error: Error) {
        let message = error.localizedDescription
        Task { @MainActor [weak self] in
            self?.discoveryError = message
        }
    }
}
