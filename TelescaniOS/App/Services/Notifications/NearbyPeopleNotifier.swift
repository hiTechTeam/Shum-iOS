import Foundation
import UIKit
import UserNotifications

struct NearbyNotificationBatch: Equatable {
    enum Kind: Equatable {
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
        encounterResetDelay: TimeInterval = 180
    ) {
        self.initialCollectionWindow = initialCollectionWindow
        self.updateCollectionWindow = updateCollectionWindow
        self.encounterResetDelay = encounterResetDelay
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
    private var aggregator = NearbyEncounterAggregator()
    private var isScanningEnabled = false
    private var isApplicationActive = true
    private var scheduleGeneration = 0

    private let requestIdentifier = "telescan.nearby-people.batch"
    private let threadIdentifier = "telescan.nearby-people"

    init(
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        self.notificationCenter = notificationCenter
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
        isApplicationActive = isActive
        aggregator.reset()
        cancelPendingNotification()
    }

    func detect(id: String) {
        guard isScanningEnabled,
              !isApplicationActive,
              UIApplication.shared.applicationState == .background,
              let update = aggregator.detect(id: id) else {
            return
        }
        apply(update)
    }

    func synchronizeNearby(ids: Set<String>) {
        guard isScanningEnabled,
              !isApplicationActive,
              UIApplication.shared.applicationState == .background else {
            return
        }

        for id in ids {
            if let update = aggregator.detect(id: id) {
                apply(update)
            }
        }
    }

    func lose(id: String) {
        guard isScanningEnabled,
              !isApplicationActive,
              UIApplication.shared.applicationState == .background,
              let update = aggregator.lose(id: id) else {
            return
        }
        apply(update)
    }

    func reset() {
        aggregator.reset()
        cancelPendingNotification()
    }

    private func requestAuthorizationIfNeeded() {
        guard isApplicationActive else { return }

        Task { [weak self] in
            guard let self else { return }
            let settings = await notificationCenter.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else {
                return
            }
            _ = try? await notificationCenter.requestAuthorization(
                options: [.alert, .sound]
            )
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
                  !isApplicationActive,
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
            try? await notificationCenter.add(request)
        }
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
