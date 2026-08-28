import Foundation
import Logging
import UIKit
import UserNotifications

struct NearbyNotificationBatch: Equatable {
    enum Kind: String, Codable, Equatable {
        case initial
        case update
    }

    let kind: Kind
    let addedCount: Int
    let totalCount: Int
    let deliveryDate: Date
}

enum NearbyNotificationUpdate: Equatable {
    case schedule(NearbyNotificationBatch)
    case cancel
}

struct NearbyNotificationState: Codable, Equatable {
    let encounteredIDs: [String]
    let nearbyIDs: [String]
    let pendingIDs: [String]
    let pendingKind: NearbyNotificationBatch.Kind?
    let deliveryDate: Date?
    let emptySince: Date?
    let hasDeliveredInitialBatch: Bool
}

protocol NearbyNotificationStateStoring: AnyObject {
    var state: NearbyNotificationState? { get }
    func save(_ state: NearbyNotificationState)
    func remove()
}

final class NearbyNotificationStateStore: NearbyNotificationStateStoring {
    static let shared = NearbyNotificationStateStore()

    private struct Envelope: Codable {
        let state: NearbyNotificationState
        let savedAt: Date
    }

    private let defaults: UserDefaults
    private let key: String
    private let maximumAge: TimeInterval

    init(
        defaults: UserDefaults = .standard,
        key: String = "telescan.nearby-notification-state.v1",
        maximumAge: TimeInterval = 30 * 60
    ) {
        self.defaults = defaults
        self.key = key
        self.maximumAge = maximumAge
    }

    var state: NearbyNotificationState? {
        guard let data = defaults.data(forKey: key),
              let envelope = try? JSONDecoder().decode(
                Envelope.self,
                from: data
              ),
              Date().timeIntervalSince(envelope.savedAt) <= maximumAge else {
            defaults.removeObject(forKey: key)
            return nil
        }
        return envelope.state
    }

    func save(_ state: NearbyNotificationState) {
        let envelope = Envelope(state: state, savedAt: Date())
        guard let data = try? JSONEncoder().encode(envelope) else { return }
        defaults.set(data, forKey: key)
    }

    func remove() {
        defaults.removeObject(forKey: key)
    }
}

final class InMemoryNearbyNotificationStateStore:
    NearbyNotificationStateStoring {
    private(set) var state: NearbyNotificationState?

    func save(_ state: NearbyNotificationState) {
        self.state = state
    }

    func remove() {
        state = nil
    }
}

struct NearbyEncounterAggregator {
    private(set) var encounteredIDs: Set<String> = []
    private(set) var nearbyIDs: Set<String> = []
    private(set) var pendingIDs: Set<String> = []

    private var pendingKind: NearbyNotificationBatch.Kind?
    private var deliveryDate: Date?
    private var emptySince: Date?
    private var hasDeliveredInitialBatch = false

    let initialCollectionWindow: TimeInterval
    let updateCollectionWindow: TimeInterval
    let encounterResetDelay: TimeInterval

    init(
        initialCollectionWindow: TimeInterval = 12,
        updateCollectionWindow: TimeInterval = 25,
        encounterResetDelay: TimeInterval = 180,
        restoring state: NearbyNotificationState? = nil
    ) {
        self.initialCollectionWindow = initialCollectionWindow
        self.updateCollectionWindow = updateCollectionWindow
        self.encounterResetDelay = encounterResetDelay
        guard let state else { return }
        encounteredIDs = Set(state.encounteredIDs)
        nearbyIDs = Set(state.nearbyIDs)
        pendingIDs = Set(state.pendingIDs)
        pendingKind = state.pendingKind
        deliveryDate = state.deliveryDate
        emptySince = state.emptySince
        hasDeliveredInitialBatch = state.hasDeliveredInitialBatch
    }

    var persistentState: NearbyNotificationState {
        NearbyNotificationState(
            encounteredIDs: encounteredIDs.sorted(),
            nearbyIDs: nearbyIDs.sorted(),
            pendingIDs: pendingIDs.sorted(),
            pendingKind: pendingKind,
            deliveryDate: deliveryDate,
            emptySince: emptySince,
            hasDeliveredInitialBatch: hasDeliveredInitialBatch
        )
    }

    mutating func detect(
        id: String,
        at now: Date = Date()
    ) -> NearbyNotificationUpdate? {
        resetEncounterAfterQuietPeriod(at: now)
        finalizeExpiredBatch(at: now)

        nearbyIDs.insert(id)
        emptySince = nil

        guard encounteredIDs.insert(id).inserted else {
            return nil
        }

        pendingIDs.insert(id)
        if deliveryDate == nil {
            pendingKind = hasDeliveredInitialBatch ? .update : .initial
            let window = hasDeliveredInitialBatch
                ? updateCollectionWindow
                : initialCollectionWindow
            deliveryDate = now.addingTimeInterval(window)
        }

        return currentBatch.map(NearbyNotificationUpdate.schedule)
    }

    mutating func lose(
        id: String,
        at now: Date = Date()
    ) -> NearbyNotificationUpdate? {
        finalizeExpiredBatch(at: now)
        guard nearbyIDs.remove(id) != nil else { return nil }

        pendingIDs.remove(id)
        if nearbyIDs.isEmpty {
            emptySince = now
        }

        guard !pendingIDs.isEmpty else {
            clearPendingBatch()
            return .cancel
        }

        return currentBatch.map(NearbyNotificationUpdate.schedule)
    }

    mutating func reset() {
        encounteredIDs.removeAll()
        nearbyIDs.removeAll()
        pendingIDs.removeAll()
        pendingKind = nil
        deliveryDate = nil
        emptySince = nil
        hasDeliveredInitialBatch = false
    }

    private var currentBatch: NearbyNotificationBatch? {
        guard let pendingKind,
              let deliveryDate,
              !pendingIDs.isEmpty else {
            return nil
        }

        return NearbyNotificationBatch(
            kind: pendingKind,
            addedCount: pendingIDs.count,
            totalCount: nearbyIDs.count,
            deliveryDate: deliveryDate
        )
    }

    private mutating func finalizeExpiredBatch(at now: Date) {
        guard let deliveryDate, now >= deliveryDate else { return }
        if pendingKind == .initial, !pendingIDs.isEmpty {
            hasDeliveredInitialBatch = true
        }
        clearPendingBatch()
    }

    private mutating func clearPendingBatch() {
        pendingIDs.removeAll()
        pendingKind = nil
        deliveryDate = nil
    }

    private mutating func resetEncounterAfterQuietPeriod(at now: Date) {
        guard nearbyIDs.isEmpty,
              let emptySince,
              now.timeIntervalSince(emptySince) >= encounterResetDelay else {
            return
        }
        reset()
    }
}

@MainActor
protocol NearbyPeopleNotifying: AnyObject {
    func setScanningEnabled(_ enabled: Bool)
    func setApplicationActive(_ isActive: Bool)
    func synchronizeNearby(ids: Set<String>)
    func detect(id: String)
    func lose(id: String)
    func reset()
}

@MainActor
final class NearbyPeopleNotifier: NearbyPeopleNotifying {
    private let notificationCenter: UNUserNotificationCenter
    private let stateStore: NearbyNotificationStateStoring
    private let logger = Logger(label: "NearbyPeopleNotifier")
    private var aggregator: NearbyEncounterAggregator
    private var isScanningEnabled = false
    private var isApplicationActive: Bool?
    private var scheduleGeneration = 0
    private var isRequestingAuthorization = false

    private let requestIdentifier = "telescan.nearby-people.batch"
    private let threadIdentifier = "telescan.nearby-people"

    init(
        notificationCenter: UNUserNotificationCenter = .current(),
        stateStore: NearbyNotificationStateStoring =
            NearbyNotificationStateStore.shared
    ) {
        self.notificationCenter = notificationCenter
        self.stateStore = stateStore
        aggregator = NearbyEncounterAggregator(
            restoring: stateStore.state
        )
    }

    func setScanningEnabled(_ enabled: Bool) {
        isScanningEnabled = enabled
        if enabled {
            requestAuthorizationIfNeeded()
        } else {
            reset()
        }
    }

    func setApplicationActive(_ isActive: Bool) {
        guard isApplicationActive != isActive else { return }
        let hadKnownApplicationState = isApplicationActive != nil
        isApplicationActive = isActive

        // Preserve an unfinished batch when CoreBluetooth relaunches the
        // process directly into the background. Every normal foreground /
        // background transition starts a fresh notification session.
        guard isActive || hadKnownApplicationState else { return }
        aggregator.reset()
        stateStore.remove()
        cancelPendingNotification()
    }

    func detect(id: String) {
        guard isScanningEnabled,
              isApplicationActive == false,
              UIApplication.shared.applicationState == .background else {
            return
        }
        let update = aggregator.detect(id: id)
        persistAggregatorState()
        if let update {
            apply(update)
        }
    }

    func synchronizeNearby(ids: Set<String>) {
        guard isScanningEnabled,
              isApplicationActive == false,
              UIApplication.shared.applicationState == .background else {
            return
        }

        var latestUpdate: NearbyNotificationUpdate?
        for id in ids {
            if let update = aggregator.detect(id: id) {
                latestUpdate = update
            }
        }
        persistAggregatorState()
        if let latestUpdate {
            apply(latestUpdate)
        }
    }

    func lose(id: String) {
        guard isScanningEnabled,
              isApplicationActive == false,
              UIApplication.shared.applicationState == .background else {
            return
        }
        let update = aggregator.lose(id: id)
        persistAggregatorState()
        if let update {
            apply(update)
        }
    }

    func reset() {
        aggregator.reset()
        stateStore.remove()
        cancelPendingNotification()
    }

    private func requestAuthorizationIfNeeded() {
        guard isApplicationActive == true,
              !isRequestingAuthorization else {
            return
        }
        isRequestingAuthorization = true

        Task { [weak self] in
            guard let self else { return }
            defer { isRequestingAuthorization = false }
            let settings = await notificationCenter.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else {
                return
            }
            do {
                _ = try await notificationCenter.requestAuthorization(
                    options: [.alert, .sound]
                )
            } catch {
                logger.error(
                    "Notification authorization failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func apply(_ update: NearbyNotificationUpdate) {
        switch update {
        case .schedule(let batch):
            schedule(batch)
        case .cancel:
            cancelPendingNotification()
        }
    }

    private func schedule(_ batch: NearbyNotificationBatch) {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [requestIdentifier]
        )

        Task { [weak self] in
            guard let self else { return }
            let settings = await notificationCenter.notificationSettings()
            guard generation == scheduleGeneration,
                  isScanningEnabled,
                  isApplicationActive == false,
                  Self.canDeliver(settings.authorizationStatus) else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = Inc.NearbyNotifications.title.localized
            switch batch.kind {
            case .initial:
                content.body = String.localizedStringWithFormat(
                    Inc.NearbyNotifications.initialCountFormat.localized,
                    batch.totalCount
                )
            case .update:
                content.body = String.localizedStringWithFormat(
                    Inc.NearbyNotifications.updateCountFormat.localized,
                    batch.addedCount,
                    batch.totalCount
                )
            }
            content.sound = .default
            content.threadIdentifier = threadIdentifier
            content.userInfo = [
                AppNotificationRouter.routeKey:
                    AppNotificationRouter.nearbyRoute
            ]

            let interval = max(
                1,
                batch.deliveryDate.timeIntervalSinceNow
            )
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: interval,
                repeats: false
            )
            let request = UNNotificationRequest(
                identifier: requestIdentifier,
                content: content,
                trigger: trigger
            )
            do {
                try await notificationCenter.add(request)
            } catch {
                logger.error(
                    "Nearby notification scheduling failed: \(error.localizedDescription)"
                )
            }
        }
    }

    private func persistAggregatorState() {
        stateStore.save(aggregator.persistentState)
    }

    private func cancelPendingNotification() {
        scheduleGeneration += 1
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [requestIdentifier]
        )
    }

    private static func canDeliver(
        _ status: UNAuthorizationStatus
    ) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            true
        case .notDetermined, .denied:
            false
        @unknown default:
            false
        }
    }
}

@MainActor
final class AppNotificationRouter: NSObject,
    UNUserNotificationCenterDelegate {
    nonisolated static let routeKey = "telescan.route"
    nonisolated static let nearbyRoute = "nearby"

    static let shared = AppNotificationRouter()

    private var openNearbyAction: (() -> Void)?

    func configure(openNearby: @escaping () -> Void) {
        openNearbyAction = openNearby
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // People are already visible while the app is active.
        completionHandler([])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let route = response.notification.request.content.userInfo[
            Self.routeKey
        ] as? String
        completionHandler()

        guard route == Self.nearbyRoute else { return }
        Task { @MainActor [weak self] in
            self?.openNearbyAction?()
        }
    }
}
