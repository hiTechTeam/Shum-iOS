import Foundation
import Testing
import UIKit
@testable import Shum

@Suite("Local nearby behavior", .serialized)
struct LocalBehaviorTests {
    @Test("Quick actions reset their in-memory and persisted state")
    func quickActionsResetOnSessionCleanup() throws {
        let suiteName = "shum.tests.quick-actions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = QuickActionsSettingsStore(defaults: defaults)
        store.isQuickChatEnabled = true
        store.isQuickClearEnabled = true
        store.isQuickBlockEnabled = true

        store.reset()

        #expect(!store.isQuickChatEnabled)
        #expect(!store.isQuickClearEnabled)
        #expect(!store.isQuickBlockEnabled)
        #expect(!QuickActionsSettingsStore(defaults: defaults).hasEnabledActions)
    }

    @Test("Saved profiles clear their in-memory state during session cleanup")
    func savedProfilesClearOnSessionCleanup() {
        let store = SavedPeopleStateStore.shared
        let user = NearbyUser(
            id: UUID(),
            name: "Saved",
            username: "@saved",
            bio: nil,
            photoURL: nil
        )
        store.removeAll()
        defer { store.removeAll() }

        _ = store.toggle(user)
        #expect(store.contains(user.id))

        store.removeAll()

        #expect(!store.contains(user.id))
        #expect(store.users.isEmpty)
        #expect(store.count == 0)
    }

    @Test("Nearby notifications aggregate people into numeric batches")
    func nearbyNotificationsAggregateNumericBatches() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var aggregator = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180
        )

        var firstBatch: NearbyNotificationBatch?
        for index in 0..<8 {
            let update = aggregator.detect(
                id: "person-\(index)",
                at: start.addingTimeInterval(Double(index))
            )
            if case .schedule(let batch) = update {
                firstBatch = batch
            }
        }

        let initial = try #require(firstBatch)
        #expect(initial.kind == .initial)
        #expect(initial.addedCount == 8)
        #expect(initial.totalCount == 8)
        #expect(initial.deliveryDate == start.addingTimeInterval(12))

        var secondBatch: NearbyNotificationBatch?
        for index in 8..<15 {
            let update = aggregator.detect(
                id: "person-\(index)",
                at: start.addingTimeInterval(13 + Double(index - 8))
            )
            if case .schedule(let batch) = update {
                secondBatch = batch
            }
        }

        let update = try #require(secondBatch)
        #expect(update.kind == .update)
        #expect(update.addedCount == 7)
        #expect(update.totalCount == 15)
        #expect(update.deliveryDate == start.addingTimeInterval(38))

        let duplicate = aggregator.detect(
            id: "person-14",
            at: start.addingTimeInterval(20)
        )
        #expect(duplicate == nil)
        #expect(aggregator.pendingIDs.count == 7)
        #expect(aggregator.nearbyIDs.count == 15)

        var thirdBatch: NearbyNotificationBatch?
        for index in 15..<17 {
            let update = aggregator.detect(
                id: "person-\(index)",
                at: start.addingTimeInterval(39 + Double(index - 15))
            )
            if case .schedule(let batch) = update {
                thirdBatch = batch
            }
        }

        let finalUpdate = try #require(thirdBatch)
        #expect(finalUpdate.kind == .update)
        #expect(finalUpdate.addedCount == 2)
        #expect(finalUpdate.totalCount == 17)
    }

    @Test("Nearby notification encounter resets after a quiet period")
    func nearbyNotificationEncounterResetsAfterQuietPeriod() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        var aggregator = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180
        )

        _ = aggregator.detect(id: "person", at: start)
        _ = aggregator.lose(id: "person", at: start.addingTimeInterval(20))

        #expect(
            aggregator.detect(
                id: "person",
                at: start.addingTimeInterval(100)
            ) == nil
        )
        _ = aggregator.lose(id: "person", at: start.addingTimeInterval(110))

        let restarted = aggregator.detect(
            id: "person",
            at: start.addingTimeInterval(300)
        )
        guard case .schedule(let batch) = restarted else {
            Issue.record("Expected a new encounter notification")
            return
        }
        #expect(batch.kind == .initial)
        #expect(batch.addedCount == 1)
        #expect(batch.totalCount == 1)
    }

    @Test("People already nearby when backgrounding do not notify")
    func alreadyNearbyPeopleBecomeNotificationBaseline() throws {
        let start = Date(timeIntervalSince1970: 2_500)
        var aggregator = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180
        )

        aggregator.markAlreadyNearby(
            ids: ["already-visible"],
            at: start
        )

        #expect(
            aggregator.detect(
                id: "already-visible",
                at: start.addingTimeInterval(1)
            ) == nil
        )
        #expect(aggregator.pendingIDs.isEmpty)

        let update = aggregator.detect(
            id: "just-arrived",
            at: start.addingTimeInterval(2)
        )
        guard case .schedule(let batch) = update else {
            Issue.record("Expected a notification for the new nearby person")
            return
        }
        #expect(batch.kind == .initial)
        #expect(batch.addedCount == 1)
        #expect(batch.totalCount == 2)
    }

    @Test("Nearby notification batch survives process recreation")
    func nearbyNotificationBatchSurvivesProcessRecreation() throws {
        let start = Date(timeIntervalSince1970: 3_000)
        var original = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180
        )

        _ = original.detect(id: "first", at: start)
        var restored = NearbyEncounterAggregator(
            initialCollectionWindow: 12,
            updateCollectionWindow: 25,
            encounterResetDelay: 180,
            restoring: original.persistentState
        )

        #expect(
            restored.detect(
                id: "first",
                at: start.addingTimeInterval(2)
            ) == nil
        )

        let update = restored.detect(
            id: "second",
            at: start.addingTimeInterval(3)
        )
        guard case .schedule(let batch) = update else {
            Issue.record("Expected the restored pending batch")
            return
        }
        #expect(batch.kind == .initial)
        #expect(batch.addedCount == 2)
        #expect(batch.totalCount == 2)
        #expect(batch.deliveryDate == start.addingTimeInterval(12))
    }

    @Test("Nearby notification state persists in defaults")
    func nearbyNotificationStatePersistsInDefaults() throws {
        let suiteName = "NearbyNotificationStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var aggregator = NearbyEncounterAggregator()
        _ = aggregator.detect(id: "person", at: Date())
        let firstStore = NearbyNotificationStateStore(
            defaults: defaults,
            key: "state"
        )
        firstStore.save(aggregator.persistentState)

        let restoredStore = NearbyNotificationStateStore(
            defaults: defaults,
            key: "state"
        )
        #expect(restoredStore.state == aggregator.persistentState)
    }

}

