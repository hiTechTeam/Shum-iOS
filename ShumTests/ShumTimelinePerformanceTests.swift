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

    @Test func bottomMessagesMoveWithKeyboardInBothDirections() async throws {
        let key = "test.timeline.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let controller = ShumTimelineController(storageKey: key)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKey()
        }
        controller.update(items: (0..<100).map { ShumTimelineItem(id: "\($0)", revision: 0) },
                          appearanceKey: "test", command: nil) { index, width in
            AnyView(Text("Message \(index)").frame(width: width, height: 44))
        }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let table = try #require(controller.view.subviews.compactMap { $0 as? UITableView }.first)
        let initialOffset = table.contentOffset.y

        let hidden = CGRect(x: 0, y: 844, width: 390, height: 300)
        let shown = CGRect(x: 0, y: 544, width: 390, height: 300)
        let restingBottom = window.safeAreaLayoutGuide.layoutFrame.maxY
        let travel = min(hidden.minY, restingBottom) - min(shown.minY, restingBottom)
        func moveKeyboard(from begin: CGRect, to end: CGRect) {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                            userInfo: [UIResponder.keyboardFrameBeginUserInfoKey: begin,
                                                       UIResponder.keyboardFrameEndUserInfoKey: end,
                                                       UIResponder.keyboardAnimationDurationUserInfoKey: 0.5,
                                                       UIResponder.keyboardAnimationCurveUserInfoKey: 7])
        }

        moveKeyboard(from: hidden, to: shown)
        controller.view.frame.size.height = 844 - travel
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(abs(table.contentOffset.y - initialOffset - travel) < 2)
        try await Task.sleep(for: .milliseconds(80))
        let rising = try #require(table.layer.presentation()?.bounds.origin.y)
        #expect(rising < initialOffset + travel - 20, "History should already move before the keyboard finishes")
        try await Task.sleep(for: .milliseconds(500))
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        #expect(abs(table.contentOffset.y - initialOffset - travel) < 2)

        moveKeyboard(from: shown, to: hidden)
        controller.view.frame.size.height = 844
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(abs(table.contentOffset.y - initialOffset) < 2)
        try await Task.sleep(for: .milliseconds(80))
        let falling = try #require(table.layer.presentation()?.bounds.origin.y)
        #expect(falling > initialOffset + 20,
                "History should still be moving down while the keyboard closes")
        try await Task.sleep(for: .milliseconds(500))
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        #expect(abs(table.contentOffset.y - initialOffset) < 2)
    }

}
