import Foundation
import SwiftUI

private final class BLECallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = UUID()
    private var accepting = true

    func ticket() -> UUID? {
        lock.withLock { accepting ? generation : nil }
    }

    func accepts(_ ticket: UUID) -> Bool {
        lock.withLock { accepting && generation == ticket }
    }

    func setAccepting(_ value: Bool, invalidate: Bool = false) {
        lock.withLock {
            if invalidate || accepting != value {
                generation = UUID()
            }
            accepting = value
        }
    }
}

protocol BLECallbackDispatching: Sendable {
    func dispatch(_ operation: @escaping @MainActor @Sendable () -> Void)
}

final class MainActorBLECallbackDispatcher: BLECallbackDispatching {
    func dispatch(_ operation: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in operation() }
    }
}

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
    @Published private(set) var userCache: [String: NearbyUser] = [:] {
        didSet {
            updateApplicationIconBadge()
        }
    }
    @Published private(set) var disappearanceCountdowns: [String: Int] = [:]
    @Published private(set) var blockedProfiles: [BlockedProfileResponse] = []
    @Published private(set) var encounterHistory: [EncounterHistoryEntry] = [] {
        didSet {
            updateApplicationIconBadge()
        }
    }
    @Published private(set) var unviewedEncounterIDs: Set<UUID> = [] {
        didSet {
            updateApplicationIconBadge()
        }
    }
    @Published private(set) var discoveryError: String?

    var visibleUsers: [NearbyUser] {
        discoveryOrder.compactMap { userCache[$0] }
    }

    var unviewedEncounterCount: Int {
        unviewedEncounterIDs.count
    }

    var accountStateGeneration: UUID {
        accountGeneration
    }

    private let bleManager: BLEManagerProtocol
    private let nearbyPeopleNotifier: NearbyPeopleNotifying
    private let blockedProfileStore: BlockedProfileStoring
    private let encounterHistoryStore: EncounterHistoryStoring
    private let encounterBufferStore: EncounterHistoryStoring
    private let unviewedEncounterStore: UnviewedEncounterStoring
    private let pendingEncounterIdentityStore:
        PendingEncounterIdentityStoring
    private let profileLoader: @MainActor (UUID) async throws
        -> TelescanProfileResponse
    private let blockedProfilesLoader: @MainActor () async throws
        -> [BlockedProfileResponse]
    private let blockSubmitter: (@MainActor (UUID) async throws
        -> BlockedProfileResponse)?
    private let unblockSubmitter: @MainActor (UUID) async throws -> Void
    private let callbackGate = BLECallbackGate()
    private let callbackDispatcher: any BLECallbackDispatching
    private var distanceTimer: Timer?
    private var presenceTimer: Timer?
    private var discoveryOrder: [String] = []
    private var rssiSamples: [String: [Int]] = [:]
    private var lastSignals: [String: Date] = [:]
    private var profileTasks: [String: Task<Void, Never>] = [:]
    private var pendingEncounterTasks: [String: Task<Void, Never>] = [:]
    private var pendingIdentityRecoveryTasks: [String: Task<Void, Never>] = [:]
    private var resolutionAttempts: [String: Int] = [:]
    private var lastHistoryUpdates: [String: Date] = [:]
    private var lastBufferUpdates: [String: Date] = [:]
    private var suppressedProfileIDs: Set<String> = []
    private var notifiedResolvedProfileIDs: Set<String> = []
    private var accountGeneration = UUID()
    private var blockedStateRevision: UInt64 = 0
    private var blockedSyncTicket: UInt64 = 0
    private var acceptsDiscoveryEvents = true
    private var isApplicationActive = true
    private let distanceUpdateInterval: TimeInterval = 10
    private let maximumRSSISamples = 30
    private let maximumProfileResolutionAttempts: Int
    private let profileRetryBaseDelay: TimeInterval
    private let maximumRetryDelay: TimeInterval
    private let encounterRetention: TimeInterval?
    private let historyUpdateInterval: TimeInterval
    private let encounterInactivityDelay: TimeInterval
    private let bufferPersistenceInterval: TimeInterval = 10
    private let nowProvider: () -> Date

    init(
        bleManager: BLEManagerProtocol = BLEManager.shared,
        nearbyPeopleNotifier: NearbyPeopleNotifying? = nil,
        blockedProfileStore: BlockedProfileStoring = BlockedProfileStore.shared,
        encounterHistoryStore: EncounterHistoryStoring =
            EncounterHistoryStore.shared,
        encounterBufferStore: EncounterHistoryStoring =
            EncounterBufferStore.shared,
        unviewedEncounterStore: UnviewedEncounterStoring? = nil,
        pendingEncounterIdentityStore: PendingEncounterIdentityStoring? = nil,
        encounterRetention: TimeInterval? = EncounterHistoryPolicy.retention,
        historyUpdateInterval: TimeInterval = 60,
        encounterInactivityDelay: TimeInterval =
            BLEPresencePolicy.activeTimeout,
        maximumProfileResolutionAttempts: Int = 5,
        profileRetryBaseDelay: TimeInterval = 2,
        maximumRetryDelay: TimeInterval = 30,
        callbackDispatcher: any BLECallbackDispatching =
            MainActorBLECallbackDispatcher(),
        profileLoader: @escaping @MainActor (UUID) async throws
            -> TelescanProfileResponse = {
                try LocalCardStore.shared.profile($0)
            },
        blockedProfilesLoader: @escaping @MainActor () async throws
            -> [BlockedProfileResponse] = {
                LocalBlockedProfiles.load()
            },
        blockSubmitter: (@MainActor (UUID) async throws
            -> BlockedProfileResponse)? = nil,
        unblockSubmitter: @escaping @MainActor (UUID) async throws -> Void = {
            _ = $0
        },
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.bleManager = bleManager
        self.nearbyPeopleNotifier = nearbyPeopleNotifier
            ?? NearbyPeopleNotifier()
        self.blockedProfileStore = blockedProfileStore
        self.encounterHistoryStore = encounterHistoryStore
        self.encounterBufferStore = encounterBufferStore
        if let unviewedEncounterStore {
            self.unviewedEncounterStore = unviewedEncounterStore
        } else if bleManager is BLEManager {
            self.unviewedEncounterStore = UnviewedEncounterStore.shared
        } else {
            self.unviewedEncounterStore = InMemoryUnviewedEncounterStore()
        }
        if let pendingEncounterIdentityStore {
            self.pendingEncounterIdentityStore = pendingEncounterIdentityStore
        } else if bleManager is BLEManager {
            self.pendingEncounterIdentityStore =
                PendingEncounterIdentityStore.shared
        } else {
            self.pendingEncounterIdentityStore =
                InMemoryPendingEncounterIdentityStore()
        }
        self.encounterRetention = encounterRetention.map { max(1, $0) }
        self.historyUpdateInterval = max(0, historyUpdateInterval)
        self.encounterInactivityDelay = max(0, encounterInactivityDelay)
        self.nowProvider = nowProvider
        self.maximumProfileResolutionAttempts = max(
            1,
            maximumProfileResolutionAttempts
        )
        self.profileRetryBaseDelay = max(0, profileRetryBaseDelay)
        self.maximumRetryDelay = max(
            self.profileRetryBaseDelay,
            maximumRetryDelay
        )
        self.callbackDispatcher = callbackDispatcher
        self.profileLoader = profileLoader
        self.blockedProfilesLoader = blockedProfilesLoader
        self.blockSubmitter = blockSubmitter
        self.unblockSubmitter = unblockSubmitter
        unviewedEncounterIDs = self.unviewedEncounterStore.ids
        bleManager.delegate = self
        bleManager.setDiscoveryEventEpoch(callbackGate.ticket())
        purgeEncounterData(canonicalIDs: blockedProfileStore.ids)
        flushBufferedEncounters()
        refreshEncounterHistory(at: nowProvider())
        recoverPendingEncounterIdentities()
        startDistanceUpdater()
        startPresenceUpdater()
        updateApplicationIconBadge()
    }

    deinit {
        distanceTimer?.invalidate()
        presenceTimer?.invalidate()
        for task in profileTasks.values {
            task.cancel()
        }
        for task in pendingEncounterTasks.values {
            task.cancel()
        }
        for task in pendingIdentityRecoveryTasks.values {
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
        setDiscoveryEventAcceptance(true, invalidate: true)
        clearDevices()
        bleManager.restartScanning()
    }

    func synchronizeBlockedProfiles() async {
        let generation = accountGeneration
        let revision = blockedStateRevision
        blockedSyncTicket += 1
        let ticket = blockedSyncTicket
        do {
            let profiles = try await blockedProfilesLoader()
            guard generation == accountGeneration,
                  revision == blockedStateRevision,
                  ticket == blockedSyncTicket else { return }
            blockedProfiles = profiles
            let serverIDs = Set(
                profiles.map { $0.telescanId.uuidString.lowercased() }
            )
            blockedProfileStore.replace(with: serverIDs)
            purgeEncounterData(canonicalIDs: serverIDs)
            let visibleBlockedIDs = devices.keys.filter(serverIDs.contains)
            for id in visibleBlockedIDs {
                loseDevice(id: id)
            }
        } catch {
            guard generation == accountGeneration else { return }
            // Preserve the last successful local block list while offline.
        }
    }

    func isCurrentAccountStateGeneration(_ generation: UUID) -> Bool {
        generation == accountGeneration
    }

    func block(_ user: NearbyUser) async throws {
        let generation = accountGeneration
        let blockedProfile: BlockedProfileResponse
        if let blockSubmitter {
            blockedProfile = try await blockSubmitter(user.id)
        } else {
            blockedProfile = BlockedProfileResponse(telescanId: user.id,
                name: user.name, username: user.username, photoUrl: user.photoURL,
                blockedAt: ISO8601DateFormatter().string(from: nowProvider()))
        }
        guard generation == accountGeneration else {
            throw CancellationError()
        }
        blockedStateRevision += 1
        blockedProfileStore.insert(user.id)
        if let index = blockedProfiles.firstIndex(where: { $0.id == user.id }) {
            blockedProfiles[index] = blockedProfile
        } else {
            blockedProfiles.insert(blockedProfile, at: 0)
        }
        LocalBlockedProfiles.save(blockedProfiles)
        purgeEncounterData(canonicalIDs: [user.discoveryID])
        loseDevice(id: user.discoveryID)
    }

    func unblock(_ profile: BlockedProfileResponse) async throws {
        let generation = accountGeneration
        try await unblockSubmitter(profile.telescanId)
        guard generation == accountGeneration else {
            throw CancellationError()
        }
        blockedStateRevision += 1
        blockedProfileStore.remove(profile.telescanId)
        blockedProfiles.removeAll { $0.id == profile.id }
        LocalBlockedProfiles.save(blockedProfiles)
        refreshEncounterHistory(at: nowProvider())
    }

    func isProfileBlocked(_ id: UUID) -> Bool {
        blockedProfileStore.ids.contains(id.uuidString.lowercased())
    }

    func clearBlockedProfileCache() {
        blockedStateRevision += 1
        blockedProfileStore.removeAll()
        blockedProfiles.removeAll()
        LocalBlockedProfiles.save([])
    }

    func resetAccountScopedState() {
        accountGeneration = UUID()
        blockedStateRevision += 1
        blockedSyncTicket += 1
        setDiscoveryEventAcceptance(false, invalidate: true)

        nearbyPeopleNotifier.setScanningEnabled(false)
        nearbyPeopleNotifier.reset()
        bleManager.stopScanning()
        bleManager.stopAdvertising()

        for task in profileTasks.values {
            task.cancel()
        }
        profileTasks.removeAll()
        for task in pendingEncounterTasks.values {
            task.cancel()
        }
        pendingEncounterTasks.removeAll()
        for task in pendingIdentityRecoveryTasks.values {
            task.cancel()
        }
        pendingIdentityRecoveryTasks.removeAll()

        encounterHistoryStore.removeAll()
        encounterBufferStore.removeAll()
        unviewedEncounterStore.removeAll()
        pendingEncounterIdentityStore.removeAll()
        blockedProfileStore.removeAll()

        devices.removeAll()
        distances.removeAll()
        userCache.removeAll()
        disappearanceCountdowns.removeAll()
        blockedProfiles.removeAll()
        encounterHistory.removeAll()
        unviewedEncounterIDs.removeAll()
        discoveryOrder.removeAll()
        rssiSamples.removeAll()
        lastSignals.removeAll()
        resolutionAttempts.removeAll()
        lastHistoryUpdates.removeAll()
        lastBufferUpdates.removeAll()
        suppressedProfileIDs.removeAll()
        notifiedResolvedProfileIDs.removeAll()
        discoveryError = nil
        nearbyPeopleNotifier.setApplicationIconBadgeCount(0)
    }

    func clearEncounterHistory() {
        for task in pendingEncounterTasks.values {
            task.cancel()
        }
        pendingEncounterTasks.removeAll()
        for task in pendingIdentityRecoveryTasks.values {
            task.cancel()
        }
        pendingIdentityRecoveryTasks.removeAll()
        encounterHistoryStore.removeAll()
        encounterBufferStore.removeAll()
        unviewedEncounterStore.removeAll()
        pendingEncounterIdentityStore.removeAll()
        encounterHistory.removeAll()
        unviewedEncounterIDs.removeAll()
        lastHistoryUpdates.removeAll()
        lastBufferUpdates.removeAll()
    }

    func removeEncounterFromHistory(_ user: NearbyUser) {
        encounterHistoryStore.remove(ids: [user.id])
        unviewedEncounterStore.remove(user.id)
        unviewedEncounterIDs.remove(user.id)
        lastHistoryUpdates.removeValue(forKey: user.discoveryID)
        refreshEncounterHistory(at: nowProvider())
    }

    func markEncounterViewed(_ id: UUID) {
        guard unviewedEncounterIDs.remove(id) != nil else { return }
        unviewedEncounterStore.remove(id)
    }

    func refreshEncounterHistory(at now: Date = Date()) {
        if let encounterRetention {
            let cutoff = now.addingTimeInterval(-encounterRetention)
            encounterHistoryStore.prune(olderThan: cutoff)
        }

        let blockedIDs = blockedProfileStore.ids
        encounterHistory = encounterHistoryStore.entries.filter {
            !blockedIDs.contains($0.user.discoveryID)
        }
        let visibleIDs = Set(encounterHistory.map(\.id))
        unviewedEncounterStore.retain(visibleIDs)
        let retainedUnviewedIDs = unviewedEncounterIDs.intersection(visibleIDs)
        if retainedUnviewedIDs != unviewedEncounterIDs {
            unviewedEncounterIDs = retainedUnviewedIDs
        }
    }

    func toggleScanning(_ enabled: Bool) {
        setDiscoveryEventAcceptance(enabled, invalidate: !enabled)
        nearbyPeopleNotifier.setScanningEnabled(enabled)
        if discoveryError != nil {
            discoveryError = nil
        }
        if enabled {
            bleManager.startScanning()
        } else {
            cancelPendingIdentityRecovery()
            bleManager.stopScanning()
            clearDevices(recordEncountersImmediately: true)
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

    func reconcileBluetoothState(
        isActive: Bool,
        scanningEnabled: Bool? = nil
    ) {
        if isApplicationActive != isActive {
            notifiedResolvedProfileIDs.removeAll()
        }
        isApplicationActive = isActive
        nearbyPeopleNotifier.setApplicationActive(isActive)
        if let scanningEnabled {
            setDiscoveryEventAcceptance(
                scanningEnabled,
                invalidate: !scanningEnabled
            )
            if !scanningEnabled {
                cancelPendingIdentityRecovery()
            }
            nearbyPeopleNotifier.setScanningEnabled(scanningEnabled)
        }
        updateDisappearanceCountdowns()
        bleManager.setApplicationActive(isActive)
        if isActive {
            bleManager.reconcileDiscoveryState()
            recoverPendingEncounterIdentities()
        } else {
            let now = Date()
            let recentlySeenIDs = Set(
                lastSignals.compactMap { id, lastSignal in
                    now.timeIntervalSince(lastSignal)
                        < BLEPresencePolicy.activeTimeout
                        && userCache[id] != nil
                        ? id
                        : nil
                }
            )
            nearbyPeopleNotifier.synchronizeNearby(ids: recentlySeenIDs)
            notifiedResolvedProfileIDs.formUnion(recentlySeenIDs)
        }
    }

    func stopAllBluetoothActivity() {
        setDiscoveryEventAcceptance(false, invalidate: true)
        cancelPendingIdentityRecovery()
        nearbyPeopleNotifier.setScanningEnabled(false)
        bleManager.stopScanning()
        bleManager.stopAdvertising()
        clearDevices(recordEncountersImmediately: true)
    }

    private func cancelPendingIdentityRecovery() {
        for task in pendingIdentityRecoveryTasks.values {
            task.cancel()
        }
        pendingIdentityRecoveryTasks.removeAll()
        pendingEncounterIdentityStore.removeAll()
    }

    private func setDiscoveryEventAcceptance(
        _ accepting: Bool,
        invalidate: Bool = false
    ) {
        acceptsDiscoveryEvents = accepting
        callbackGate.setAccepting(accepting, invalidate: invalidate)
        bleManager.setDiscoveryEventEpoch(callbackGate.ticket())
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
        refreshEncounterHistory(at: nowProvider())
    }

    private func updateApplicationIconBadge() {
        nearbyPeopleNotifier.setApplicationIconBadgeCount(
            visibleUsers.count + unviewedEncounterCount
        )
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

    func clearDevices(recordEncountersImmediately: Bool = false) {
        if recordEncountersImmediately {
            let fallbackDate = nowProvider()
            for (id, user) in userCache {
                pendingEncounterTasks[id]?.cancel()
                pendingEncounterTasks.removeValue(forKey: id)
                publishEncounter(
                    user,
                    at: lastSignals[id] ?? fallbackDate,
                    force: true
                )
            }
        }
        for task in profileTasks.values {
            task.cancel()
        }
        profileTasks.removeAll()
        resolutionAttempts.removeAll()
        suppressedProfileIDs.removeAll()
        devices.removeAll()
        distances.removeAll()
        userCache.removeAll()
        discoveryOrder.removeAll()
        disappearanceCountdowns.removeAll()
        rssiSamples.removeAll()
        lastSignals.removeAll()
        lastHistoryUpdates.removeAll()
        lastBufferUpdates.removeAll()
        notifiedResolvedProfileIDs.removeAll()
        refreshEncounterHistory(at: nowProvider())
    }

    private func receiveDevice(id: String, rssi: Int) {
        guard acceptsDiscoveryEvents else { return }
        guard let uuid = UUID(uuidString: id) else { return }
        let canonicalID = uuid.uuidString.lowercased()
        pendingEncounterTasks[canonicalID]?.cancel()
        pendingEncounterTasks.removeValue(forKey: canonicalID)
        guard !blockedProfileStore.ids.contains(canonicalID) else { return }
        let now = nowProvider()
        if userCache[canonicalID] == nil {
            pendingEncounterIdentityStore.record(id: uuid, seenAt: now)
        }
        let isNew = devices[canonicalID] == nil
        devices[canonicalID] = rssi
        if isNew {
            discoveryOrder.insert(canonicalID, at: 0)
            refreshEncounterHistory(at: nowProvider())
        }
        lastSignals[canonicalID] = now
        if let user = userCache[canonicalID] {
            bufferEncounter(user, at: now)
            scheduleEncounterAfterInactivity(user, lastSeenAt: now)
        }
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
        let generation = accountGeneration

        profileTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  generation == self.accountGeneration,
                  self.devices[id] != nil else { return }
            await self.resolveProfile(for: id, generation: generation)
        }
    }

    private func resolveProfile(for id: String, generation: UUID) async {
        guard generation == accountGeneration else { return }
        guard let requestedID = UUID(uuidString: id) else {
            profileTasks[id] = nil
            return
        }

        do {
            let response = try await profileLoader(requestedID)
            try Task.checkCancellation()
            guard generation == accountGeneration else { return }
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
            SavedPeopleStateStore.shared.refreshProfile(user)
            notifyResolvedProfileIfNeeded(id: id)
            let lastSeenAt = lastSignals[id] ?? nowProvider()
            bufferEncounter(user, at: lastSeenAt, force: true)
            pendingEncounterIdentityStore.remove(ids: [user.id])
            scheduleEncounterAfterInactivity(
                user,
                lastSeenAt: lastSeenAt
            )
            resolutionAttempts[id] = 0
            profileTasks[id] = nil
        } catch is CancellationError {
            if generation == accountGeneration {
                profileTasks[id] = nil
            }
        } catch {
            guard generation == accountGeneration else { return }
            profileTasks[id] = nil
            if isTerminalProfileError(error) {
                nearbyPeopleNotifier.lose(id: id)
                userCache.removeValue(forKey: id)
                resolutionAttempts.removeValue(forKey: id)
                suppressedProfileIDs.insert(id)
                pendingEncounterIdentityStore.remove(ids: [requestedID])
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

    private func notifyResolvedProfileIfNeeded(id: String) {
        guard !isApplicationActive,
              devices[id] != nil,
              userCache[id] != nil,
              !blockedProfileStore.ids.contains(id),
              notifiedResolvedProfileIDs.insert(id).inserted else {
            return
        }
        nearbyPeopleNotifier.detect(id: id)
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
            guard !trimmed.isEmpty, URL(string: trimmed)?.isFileURL == true else { return nil }
            return trimmed
        }
        return NearbyUser(
            id: profile.telescanId,
            name: name,
            username: username,
            bio: profile.bio?.trimmingCharacters(in: .whitespacesAndNewlines),
            photoURL: photoURL
        )
    }

    private func isTerminalProfileError(_ error: Error) -> Bool {
        if error is NearbyProfileError { return true }
        switch error {
        case LocalCardError.invalidProfile, LocalCardError.invalidPhoto, LocalCardError.invalidPacket: return true
        default: return false
        }
    }

    private func shouldRetryProfileResolution(_ error: Error) -> Bool {
        error is LocalCardError || error is URLError
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
        discoveryOrder.removeAll { $0 == canonicalID }
        disappearanceCountdowns.removeValue(forKey: canonicalID)
        rssiSamples.removeValue(forKey: canonicalID)
        lastSignals.removeValue(forKey: canonicalID)
        lastHistoryUpdates.removeValue(forKey: canonicalID)
        lastBufferUpdates.removeValue(forKey: canonicalID)
        notifiedResolvedProfileIDs.remove(canonicalID)
        refreshEncounterHistory(at: nowProvider())
    }

    private func scheduleEncounterAfterInactivity(
        _ user: NearbyUser,
        lastSeenAt: Date
    ) {
        let canonicalID = user.discoveryID
        guard !blockedProfileStore.ids.contains(canonicalID) else { return }

        pendingEncounterTasks[canonicalID]?.cancel()
        let delay = encounterInactivityDelay
        let generation = accountGeneration
        pendingEncounterTasks[canonicalID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard let self else { return }
            guard generation == self.accountGeneration else { return }
            self.pendingEncounterTasks.removeValue(forKey: canonicalID)
            guard !self.blockedProfileStore.ids.contains(canonicalID) else {
                return
            }
            self.loseDevice(id: canonicalID)
            self.publishEncounter(user, at: lastSeenAt, force: true)
        }
    }

    private func publishEncounter(
        _ user: NearbyUser,
        at date: Date,
        force: Bool = false
    ) {
        recordEncounter(user, at: date, force: force)
        encounterBufferStore.remove(ids: [user.id])
        lastBufferUpdates.removeValue(forKey: user.discoveryID)
    }

    private func bufferEncounter(
        _ user: NearbyUser,
        at date: Date,
        force: Bool = false
    ) {
        let canonicalID = user.discoveryID
        guard !blockedProfileStore.ids.contains(canonicalID) else { return }
        if !force,
           let lastUpdate = lastBufferUpdates[canonicalID],
           date.timeIntervalSince(lastUpdate) < bufferPersistenceInterval {
            return
        }

        encounterBufferStore.record(user, seenAt: date)
        lastBufferUpdates[canonicalID] = date
    }

    private func recordEncounter(
        _ user: NearbyUser,
        at date: Date,
        force: Bool = false
    ) {
        let canonicalID = user.discoveryID
        guard !blockedProfileStore.ids.contains(canonicalID) else { return }

        if !force,
           let lastUpdate = lastHistoryUpdates[canonicalID],
           date.timeIntervalSince(lastUpdate) < historyUpdateInterval {
            return
        }

        let referenceDate = max(nowProvider(), date)
        let isAlreadyInHistory = isEncounterInCurrentHistory(
            user.id,
            at: referenceDate
        )
        encounterHistoryStore.record(user, seenAt: date)
        if !isAlreadyInHistory {
            markEncounterAsUnviewed(user.id)
        }
        lastHistoryUpdates[canonicalID] = max(
            lastHistoryUpdates[canonicalID] ?? date,
            date
        )
        refreshEncounterHistory(at: max(nowProvider(), date))
    }

    private func purgeEncounterData(canonicalIDs: Set<String>) {
        let ids = Set(canonicalIDs.compactMap { UUID(uuidString: $0) })
        for canonicalID in canonicalIDs {
            pendingEncounterTasks[canonicalID]?.cancel()
            pendingEncounterTasks.removeValue(forKey: canonicalID)
            pendingIdentityRecoveryTasks[canonicalID]?.cancel()
            pendingIdentityRecoveryTasks.removeValue(forKey: canonicalID)
            notifiedResolvedProfileIDs.remove(canonicalID)
            nearbyPeopleNotifier.lose(id: canonicalID)
        }
        encounterHistoryStore.remove(ids: ids)
        encounterBufferStore.remove(ids: ids)
        pendingEncounterIdentityStore.remove(ids: ids)
        for id in ids {
            unviewedEncounterStore.remove(id)
            unviewedEncounterIDs.remove(id)
        }
        lastHistoryUpdates = lastHistoryUpdates.filter {
            !canonicalIDs.contains($0.key)
        }
        lastBufferUpdates = lastBufferUpdates.filter {
            !canonicalIDs.contains($0.key)
        }
        refreshEncounterHistory(at: nowProvider())
    }

    private func flushBufferedEncounters() {
        let bufferedEntries = encounterBufferStore.entries
        guard !bufferedEntries.isEmpty else { return }

        let blockedIDs = blockedProfileStore.ids
        for entry in bufferedEntries
        where !blockedIDs.contains(entry.user.discoveryID) {
            let isAlreadyInHistory = isEncounterInCurrentHistory(
                entry.id,
                at: max(nowProvider(), entry.lastSeen)
            )
            encounterHistoryStore.record(
                entry.user,
                seenAt: entry.lastSeen
            )
            if !isAlreadyInHistory {
                markEncounterAsUnviewed(entry.id)
            }
        }
        encounterBufferStore.removeAll()
    }

    private func isEncounterInCurrentHistory(
        _ id: UUID,
        at referenceDate: Date
    ) -> Bool {
        guard let existing = encounterHistoryStore.entries.first(
            where: { $0.id == id }
        ) else {
            return false
        }
        guard let encounterRetention else { return true }
        return existing.lastSeen >= referenceDate.addingTimeInterval(
            -encounterRetention
        )
    }

    private func markEncounterAsUnviewed(_ id: UUID) {
        unviewedEncounterStore.insert(id)
        unviewedEncounterIDs.insert(id)
    }

    private func recoverPendingEncounterIdentities() {
        let now = nowProvider()
        if let encounterRetention {
            pendingEncounterIdentityStore.prune(
                olderThan: now.addingTimeInterval(-encounterRetention)
            )
        }

        for entry in pendingEncounterIdentityStore.entries {
            let canonicalID = entry.id.uuidString.lowercased()
            if blockedProfileStore.ids.contains(canonicalID) {
                pendingEncounterIdentityStore.remove(ids: [entry.id])
                continue
            }
            guard pendingIdentityRecoveryTasks[canonicalID] == nil else {
                continue
            }

            let generation = accountGeneration
            pendingIdentityRecoveryTasks[canonicalID] = Task {
                [weak self] in
                guard let self else { return }
                defer {
                    if generation == self.accountGeneration {
                        self.pendingIdentityRecoveryTasks.removeValue(
                            forKey: canonicalID
                        )
                    }
                }

                do {
                    let response = try await self.profileLoader(entry.id)
                    try Task.checkCancellation()
                    guard generation == self.accountGeneration else { return }
                    let user = try self.validatedUser(
                        response,
                        requestedID: entry.id
                    )
                    guard !self.blockedProfileStore.ids.contains(
                        canonicalID
                    ) else {
                        self.pendingEncounterIdentityStore.remove(
                            ids: [entry.id]
                        )
                        return
                    }
                    self.recordEncounter(
                        user,
                        at: entry.lastSeen,
                        force: true
                    )
                    self.pendingEncounterIdentityStore.remove(
                        ids: [entry.id]
                    )
                } catch is CancellationError {
                    return
                } catch {
                    guard generation == self.accountGeneration else { return }
                    if self.isTerminalProfileError(error) {
                        self.pendingEncounterIdentityStore.remove(
                            ids: [entry.id]
                        )
                    }
                }
            }
        }
    }
}

extension PeopleViewModel: BLEManagerDelegate {
    nonisolated func didReceiveProfile(id: String, epoch: UUID) {
        callbackDispatcher.dispatch { @MainActor [weak self] in
            guard let self, self.callbackGate.accepts(epoch) else { return }
            Task { @MainActor in await self.refreshUser(telescanID: id) }
        }
    }

    nonisolated func didDiscoverDevice(id: String, rssi: Int, epoch: UUID) {
        callbackDispatcher.dispatch { @MainActor [weak self] in
            guard let self, self.callbackGate.accepts(epoch) else { return }
            self.receiveDevice(id: id, rssi: rssi)
        }
    }

    nonisolated func didUpdateDevice(id: String, rssi: Int, epoch: UUID) {
        callbackDispatcher.dispatch { @MainActor [weak self] in
            guard let self, self.callbackGate.accepts(epoch) else { return }
            self.receiveDevice(id: id, rssi: rssi)
        }
    }

    nonisolated func didLoseDevice(id: String, epoch: UUID) {
        callbackDispatcher.dispatch { @MainActor [weak self] in
            guard let self, self.callbackGate.accepts(epoch) else { return }
            self.loseDevice(id: id)
        }
    }

    nonisolated func didFail(with error: Error, epoch: UUID) {
        let message = error.localizedDescription
        callbackDispatcher.dispatch { @MainActor [weak self] in
            guard let self, self.callbackGate.accepts(epoch) else { return }
            self.discoveryError = message
        }
    }
}
