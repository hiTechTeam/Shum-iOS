import Foundation
import Testing
import UIKit
@preconcurrency @testable import Shum

/// Background pushes wake the app to fetch messages; none of them may be lost.
@Suite("Shum push wake-ups", .serialized)
@MainActor
struct ShumPushWakeTests {
    // ShumPushService is a process-wide singleton whose wake handler cannot be
    // removed, so the launch-order scenario is covered by one ordered test.
    @Test func wakeUpsSurviveLaunchOrderAndAreConsumedOnce() {
        let service = ShumPushService.shared
        var results: [UIBackgroundFetchResult] = []

        service.handleRemoteNotification(["shum": ["kind": "message"]]) { results.append($0) }
        service.handleRemoteNotification(["aps": ["content-available": 1]]) { results.append($0) }
        #expect(results == [.noData, .noData], "Pushes without an event identifier finish immediately")

        let early = "early-\(UUID().uuidString)"
        service.handleRemoteNotification(["shum": ["event_id": early, "kind": "message"]]) { results.append($0) }
        #expect(results.count == 2, "A push that arrives before the coordinator is kept, not dropped")

        var woken: [String] = []
        service.configureBackgroundWake { eventID, completion in
            woken.append(eventID)
            completion(.newData)
        }
        #expect(woken == [early])
        #expect(results == [.noData, .noData, .newData])

        let late = "late-\(UUID().uuidString)"
        service.handleRemoteNotification(["shum": ["event_id": late, "kind": "invitation"]]) { results.append($0) }
        #expect(woken == [early, late])
        #expect(results.last == .newData)

        #expect(service.consumeRemoteEvent(early))
        #expect(!service.consumeRemoteEvent(early), "An event is consumed only once")
        #expect(service.consumeRemoteEvent(late))
        #expect(!service.consumeRemoteEvent("unknown-\(UUID().uuidString)"))
    }
}
