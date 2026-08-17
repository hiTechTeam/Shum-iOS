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
    private(set) var devices: [String: Int] = [:]
    @Published private(set) var distances: [String: Int] = [:]
    @Published private(set) var userCache: [String: NearbyUser] = [:]
    @Published private(set) var disappearanceCountdowns: [String: Int] = [:]
    @Published private(set) var blockedProfiles: [BlockedProfileResponse] = []
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
    private let nearbyPeopleNotifier: NearbyPeopleNotifying
    private let blockedProfileStore: BlockedProfileStoring
    private let profileLoader: @MainActor (UUID) async throws
        -> TelescanProfileResponse
    private let blockedProfilesLoader: @MainActor () async throws
        -> [BlockedProfileResponse]
    private let reportSubmitter: @MainActor (
        UUID,
        ReportReason,
        String?
    ) async throws -> ReportResponse
    private let blockSubmitter: @MainActor (UUID) async throws
        -> BlockedProfileResponse
    private let unblockSubmitter: @MainActor (UUID) async throws -> Void
    private var distanceTimer: Timer?
    private var presenceTimer: Timer?
    private var rssiSamples: [String: [Int]] = [:]
    private var lastSignals: [String: Date] = [:]
    private var profileTasks: [String: Task<Void, Never>] = [:]
    private var resolutionAttempts: [String: Int] = [:]
    private var suppressedProfileIDs: Set<String> = []
    private var isApplicationActive = true
    private let distanceUpdateInterval: TimeInterval = 3
    private let maximumRSSISamples = 30
    private let maximumProfileResolutionAttempts: Int
    private let profileRetryBaseDelay: TimeInterval
    private let maximumRetryDelay: TimeInterval

    init(
        bleManager: BLEManagerProtocol = BLEManager.shared,
        nearbyPeopleNotifier: NearbyPeopleNotifying? = nil,
        blockedProfileStore: BlockedProfileStoring = BlockedProfileStore.shared,
        maximumProfileResolutionAttempts: Int = 5,
        profileRetryBaseDelay: TimeInterval = 2,
        maximumRetryDelay: TimeInterval = 30,
        profileLoader: @escaping @MainActor (UUID) async throws
            -> TelescanProfileResponse = {
                try await FetchService.fetch.profile(telescanID: $0)
            },
        blockedProfilesLoader: @escaping @MainActor () async throws
            -> [BlockedProfileResponse] = {
                try await FetchService.fetch.blockedProfiles()
            },
        reportSubmitter: @escaping @MainActor (
            UUID,
            ReportReason,
            String?
        ) async throws -> ReportResponse = { id, reason, details in
            try await FetchService.fetch.submitReport(
                targetID: id,
                reason: reason,
                details: details
            )
        },
        blockSubmitter: @escaping @MainActor (UUID) async throws
            -> BlockedProfileResponse = { id in
                try await FetchService.fetch.blockProfile(telescanID: id)
            },
        unblockSubmitter: @escaping @MainActor (UUID) async throws -> Void = {
            try await FetchService.fetch.unblockProfile(telescanID: $0)
            }
    ) {
        self.bleManager = bleManager
        self.nearbyPeopleNotifier = nearbyPeopleNotifier
            ?? NearbyPeopleNotifier()
        self.blockedProfileStore = blockedProfileStore
        self.maximumProfileResolutionAttempts = max(
            1,
            maximumProfileResolutionAttempts
        )
        self.profileRetryBaseDelay = max(0, profileRetryBaseDelay)
        self.maximumRetryDelay = max(
            self.profileRetryBaseDelay,
            maximumRetryDelay
        )
        self.profileLoader = profileLoader
        self.blockedProfilesLoader = blockedProfilesLoader
        self.reportSubmitter = reportSubmitter
        self.blockSubmitter = blockSubmitter
        self.unblockSubmitter = unblockSubmitter
        bleManager.delegate = self
        startDistanceUpdater()
        startPresenceUpdater()
    }

    deinit {
        distanceTimer?.invalidate()
        presenceTimer?.invalidate()
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
        suppressedProfileIDs.remove(telescanID)
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
            suppressedProfileIDs.remove(id)
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

    func synchronizeBlockedProfiles() async {
        do {
            let profiles = try await blockedProfilesLoader()
            blockedProfiles = profiles
            let serverIDs = Set(
                profiles.map { $0.telescanId.uuidString.lowercased() }
            )
            blockedProfileStore.replace(with: serverIDs)
            let visibleBlockedIDs = devices.keys.filter(serverIDs.contains)
            for id in visibleBlockedIDs {
                loseDevice(id: id)
            }
        } catch {
            // Preserve the last successful local block list while offline.
        }
    }

    func submitReport(
        for user: NearbyUser,
        reason: ReportReason,
        details: String?
    ) async throws {
        _ = try await reportSubmitter(user.id, reason, details)
    }

    func block(_ user: NearbyUser) async throws {
        let blockedProfile = try await blockSubmitter(user.id)
        blockedProfileStore.insert(user.id)
        if let index = blockedProfiles.firstIndex(where: { $0.id == user.id }) {
            blockedProfiles[index] = blockedProfile
        } else {
            blockedProfiles.insert(blockedProfile, at: 0)
        }
        loseDevice(id: user.discoveryID)
    }

    func unblock(_ profile: BlockedProfileResponse) async throws {
        try await unblockSubmitter(profile.telescanId)
        blockedProfileStore.remove(profile.telescanId)
        blockedProfiles.removeAll { $0.id == profile.id }
    }

    func clearBlockedProfileCache() {
        blockedProfileStore.removeAll()
        blockedProfiles.removeAll()
    }

    func toggleScanning(_ enabled: Bool) {
        nearbyPeopleNotifier.setScanningEnabled(enabled)
        if discoveryError != nil {
            discoveryError = nil
        }
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
        isApplicationActive = isActive
        nearbyPeopleNotifier.setApplicationActive(isActive)
        updateDisappearanceCountdowns()
        bleManager.setApplicationActive(isActive)
        if isActive {
            bleManager.reconcileDiscoveryState()
        } else {
            let now = Date()
            let recentlySeenIDs = Set(
                lastSignals.compactMap { id, lastSignal in
                    now.timeIntervalSince(lastSignal)
                        < BLEPresencePolicy.signalLossIndicatorDelay
                        && userCache[id] != nil
                        ? id
                        : nil
                }
            )
            nearbyPeopleNotifier.synchronizeNearby(ids: recentlySeenIDs)
        }
    }

    func stopAllBluetoothActivity() {
        nearbyPeopleNotifier.setScanningEnabled(false)
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

    private func startPresenceUpdater() {
        presenceTimer?.invalidate()
        let timer = Timer(
            timeInterval: BLEPresencePolicy.countdownUpdateInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updateDisappearanceCountdowns()
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        presenceTimer = timer
    }

    func updateDisappearanceCountdowns(at now: Date = Date()) {
        guard isApplicationActive else {
            if !disappearanceCountdowns.isEmpty {
                disappearanceCountdowns.removeAll()
            }
            return
        }

        var updated: [String: Int] = [:]
        for (id, lastSignal) in lastSignals where devices[id] != nil {
            let silenceDuration = now.timeIntervalSince(lastSignal)
            guard silenceDuration >= BLEPresencePolicy.signalLossIndicatorDelay else {
                continue
            }

            let remaining = BLEPresencePolicy.activeTimeout - silenceDuration
            updated[id] = max(1, Int(ceil(remaining)))
        }

        if updated != disappearanceCountdowns {
            disappearanceCountdowns = updated
        }
    }

    private func recalculateDistances() {
        var updated: [String: Int] = [:]
        for (id, rssi) in devices {
            let samples = rssiSamples[id] ?? [rssi]
            let sorted = samples.sorted()
            updated[id] = distanceFromRSSI(sorted[sorted.count / 2])
        }
        if updated != distances {
            distances = updated
        }
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
        suppressedProfileIDs.removeAll()
        devices.removeAll()
        distances.removeAll()
        userCache.removeAll()
        disappearanceCountdowns.removeAll()
        rssiSamples.removeAll()
        lastSignals.removeAll()
    }

    private func receiveDevice(id: String, rssi: Int) {
        guard let uuid = UUID(uuidString: id) else { return }
        let canonicalID = uuid.uuidString.lowercased()
        guard !blockedProfileStore.ids.contains(canonicalID) else { return }
        let isNew = devices[canonicalID] == nil
        devices[canonicalID] = rssi
        lastSignals[canonicalID] = Date()
        if disappearanceCountdowns[canonicalID] != nil {
            disappearanceCountdowns.removeValue(forKey: canonicalID)
        }
        rssiSamples[canonicalID, default: []].append(rssi)
        if rssiSamples[canonicalID, default: []].count > maximumRSSISamples {
            rssiSamples[canonicalID]?.removeFirst()
        }
        if isNew {
            distances[canonicalID] = distanceFromRSSI(rssi)
        }
        if discoveryError != nil {
            discoveryError = nil
        }
        scheduleProfileResolution(for: canonicalID, immediately: isNew)
    }

    private func scheduleProfileResolution(
        for id: String,
        immediately: Bool,
        force: Bool = false
    ) {
        guard devices[id] != nil,
              profileTasks[id] == nil,
              force || !suppressedProfileIDs.contains(id),
              force || userCache[id] == nil else {
            return
        }

        let attempt = resolutionAttempts[id, default: 0]
        let delay = immediately
            ? 0
            : min(
                profileRetryBaseDelay * pow(2, Double(max(0, attempt - 1))),
                maximumRetryDelay
            )

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
            guard !blockedProfileStore.ids.contains(id) else {
                loseDevice(id: id)
                return
            }
            userCache[id] = user
            nearbyPeopleNotifier.detect(id: id)
            resolutionAttempts[id] = 0
            profileTasks[id] = nil
        } catch is CancellationError {
            profileTasks[id] = nil
        } catch {
            profileTasks[id] = nil
            if isTerminalProfileError(error) {
                userCache.removeValue(forKey: id)
                resolutionAttempts.removeValue(forKey: id)
                suppressedProfileIDs.insert(id)
                return
            }
            resolutionAttempts[id, default: 0] += 1
            guard shouldRetryProfileResolution(error),
                  resolutionAttempts[id, default: 0]
                    < maximumProfileResolutionAttempts else {
                suppressedProfileIDs.insert(id)
                return
            }
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

    private func isTerminalProfileError(_ error: Error) -> Bool {
        if error is NearbyProfileError {
            return true
        }
        guard case APIClientError.httpStatus(let status) = error else {
            return false
        }
        return (400...499).contains(status)
            && status != 408
            && status != 425
            && status != 429
    }

    private func shouldRetryProfileResolution(_ error: Error) -> Bool {
        if error is URLError {
            return true
        }
        switch error {
        case APIClientError.invalidResponse:
            return true
        case APIClientError.httpStatus(let status):
            return status == 408
                || status == 425
                || status == 429
                || (500...599).contains(status)
        default:
            return false
        }
    }

    private func loseDevice(id: String) {
        guard let uuid = UUID(uuidString: id) else { return }
        let canonicalID = uuid.uuidString.lowercased()
        nearbyPeopleNotifier.lose(id: canonicalID)
        profileTasks[canonicalID]?.cancel()
        profileTasks.removeValue(forKey: canonicalID)
        resolutionAttempts.removeValue(forKey: canonicalID)
        suppressedProfileIDs.remove(canonicalID)
        devices.removeValue(forKey: canonicalID)
        distances.removeValue(forKey: canonicalID)
        userCache.removeValue(forKey: canonicalID)
        disappearanceCountdowns.removeValue(forKey: canonicalID)
        rssiSamples.removeValue(forKey: canonicalID)
        lastSignals.removeValue(forKey: canonicalID)
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
