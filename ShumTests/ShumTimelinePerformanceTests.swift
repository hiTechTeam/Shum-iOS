import SwiftUI
import Testing
@testable import Shum

@Suite("Conversation opening layout", .serialized)
@MainActor
struct ShumTimelinePerformanceTests {
    @Test func openingLongHistoryOnlyBuildsViewportRowsAndStaysAtBottom() {
        let key = "test.timeline.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let controller = ShumTimelineController(storageKey: key)
        var built = Set<Int>()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.update(items: (0..<1000).map { ShumTimelineItem(id: "\($0)", revision: 0) },
                          appearanceKey: "test", command: nil) { index, width in
            built.insert(index)
            return AnyView(Text("Message \(index)").frame(width: width, height: index % 3 == 0 ? 140 : 44))
        }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let table = controller.view.subviews.compactMap { $0 as? UITableView }.first!
        #expect(built.count < 80, "Opening must not measure all 1,000 rows: \(built.count)")
        #expect(table.indexPathsForVisibleRows?.contains(IndexPath(row: 999, section: 0)) == true)
        let bottomGap = table.contentSize.height + table.contentInset.bottom - table.bounds.height - table.contentOffset.y
        #expect(abs(bottomGap) < 2)
        // Keyboard/composer resizing must not lose the bottom anchor.
        controller.view.frame.size.height = 550
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(table.indexPathsForVisibleRows?.contains(IndexPath(row: 999, section: 0)) == true)
        window.isHidden = true
    }
    @Test func openingHistoryRestoresReadingAnchorWithEstimatedRows() {
        let key = "test.timeline.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        ShumTimelinePosition(messageID: "500", offset: -20, atBottom: false, lastMessageID: "999").save(key: key)
        let controller = ShumTimelineController(storageKey: key)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.isHidden = false
        controller.update(items: (0..<1000).map { ShumTimelineItem(id: "\($0)", revision: 0) },
                          appearanceKey: "test", command: nil) { index, width in
            AnyView(Text("Message \(index)").frame(width: width, height: index % 3 == 0 ? 140 : 44))
        }
        controller.view.frame = window.bounds
        for _ in 0..<3 {
            controller.view.setNeedsLayout()
            controller.view.layoutIfNeeded()
        }
        let table = controller.view.subviews.compactMap { $0 as? UITableView }.first!
        let anchor = IndexPath(row: 500, section: 0)
        #expect(table.indexPathsForVisibleRows?.contains(anchor) == true)
        let offset = table.rectForRow(at: anchor).minY - table.contentOffset.y - table.contentInset.top
        #expect(abs(offset + 20) < 2)
        window.isHidden = true
    }

}
