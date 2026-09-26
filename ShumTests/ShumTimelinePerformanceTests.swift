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

    @Test(arguments: [3, 12, 18, 100])
    func bottomMessagesMoveWithKeyboardInBothDirections(rowCount: Int) async throws {
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
        controller.update(items: (0..<rowCount).map { ShumTimelineItem(id: "\($0)", revision: 0) },
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
        let shownOffset = max(-table.contentInset.top,
                              table.contentSize.height + table.contentInset.bottom - (844 - travel))
        let visibleTravel = shownOffset - initialOffset
        func moveKeyboard(from begin: CGRect, to end: CGRect) {
            NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: nil,
                                            userInfo: [UIResponder.keyboardFrameBeginUserInfoKey: begin,
                                                       UIResponder.keyboardFrameEndUserInfoKey: end,
                                                       UIResponder.keyboardAnimationDurationUserInfoKey: 0.5,
                                                       UIResponder.keyboardAnimationCurveUserInfoKey: 7])
        }

        // The mid-animation samples are only meaningful while the 0.5 s keyboard
        // animation is still running; a loaded machine can resume the task later.
        func sampledDuringAnimation(since start: ContinuousClock.Instant) -> Bool {
            ContinuousClock.now - start < .milliseconds(400)
        }

        var animationStart = ContinuousClock.now
        moveKeyboard(from: hidden, to: shown)
        controller.view.frame.size.height = 844 - travel
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(abs(table.contentOffset.y - shownOffset) < 2)
        try await Task.sleep(for: .milliseconds(80))
        let rising = try #require(table.layer.presentation()?.bounds.origin.y)
        if visibleTravel > 40, sampledDuringAnimation(since: animationStart) {
            #expect(rising < shownOffset - 20, "History should already move before the keyboard finishes")
        }
        try await Task.sleep(for: .milliseconds(500))
        let beforeKeyboardSettles = table.contentOffset.y
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        #expect(abs(table.contentOffset.y - beforeKeyboardSettles) < 2,
                "Finishing the keyboard animation must not snap the history to another offset")
        #expect(abs(table.contentOffset.y - shownOffset) < 2)

        animationStart = ContinuousClock.now
        moveKeyboard(from: shown, to: hidden)
        controller.view.frame.size.height = 844
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        #expect(abs(table.contentOffset.y - initialOffset) < 2)
        try await Task.sleep(for: .milliseconds(80))
        let falling = try #require(table.layer.presentation()?.bounds.origin.y)
        if visibleTravel > 40, sampledDuringAnimation(since: animationStart) {
            #expect(falling > initialOffset + 20,
                    "History should still be moving down while the keyboard closes")
        }
        try await Task.sleep(for: .milliseconds(500))
        NotificationCenter.default.post(name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        #expect(abs(table.contentOffset.y - initialOffset) < 2)
    }

    @Test func historyKeepsItsGapToComposerDuringRealKeyboardAnimation() async throws {
        let key = "test.timeline.keyboard.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let input = UITextField()
        input.placeholder = "Message"
        let host = UIHostingController(rootView: KeyboardTimelineFixture(key: key, input: input))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            input.resignFirstResponder()
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKey()
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        func findTable(_ view: UIView) -> UITableView? {
            if let table = view as? UITableView { return table }
            return view.subviews.lazy.compactMap { findTable($0) }.first
        }
        let table = try #require(findTable(host.view))
        func gap() -> CGFloat {
            let target = window.layer.presentation() ?? window.layer
            let inputLayer = input.layer.presentation() ?? input.layer
            let tableLayer = table.layer.presentation() ?? table.layer
            let inputTop = inputLayer.convert(CGPoint(x: 0, y: inputLayer.bounds.minY), to: target).y
            let messageBottom = tableLayer.convert(CGPoint(x: 0, y: table.contentSize.height), to: target).y
            return inputTop - messageBottom
        }
        let restingGap = gap()
        let initialInputTop = input.convert(input.bounds, to: window).minY
        for cycle in 0..<2 {
            for opening in [true, false] {
                if opening { #expect(input.becomeFirstResponder()) }
                else { #expect(input.resignFirstResponder()) }
                var gaps: [CGFloat] = []
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(16))
                    gaps.append(gap())
                }
                let displacement = initialInputTop - input.convert(input.bounds, to: window).minY
                if opening {
                    #expect(displacement > 100, "This check requires a visible software keyboard")
                } else {
                    #expect(abs(displacement) < 2)
                }
                let maximumDrift = gaps.map { abs($0 - restingGap) }.max() ?? 0
                #expect(maximumDrift < 4,
                        "Cycle \(cycle), opening \(opening): gap drifted by \(maximumDrift) points: \(gaps)")
            }
        }
    }

}


private struct KeyboardTimelineFixture: View {
    let key: String
    let input: UITextField
    var body: some View {
        GeometryReader { geometry in
            ShumConversationTimeline(
                items: (0..<100).map { ShumTimelineItem(id: "\($0)", revision: 0) },
                storageKey: key, appearanceKey: "test", command: nil,
                contentInsets: geometry.safeAreaInsets, bottomChanged: { _ in }, tapped: {}
            ) { index, width in
                Text("Message \(index)").frame(width: width, height: 44)
            }
            .ignoresSafeArea(.container, edges: .vertical)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            KeyboardTestInput(input: input).frame(height: 46).padding(.vertical, 8)
        }
    }
}

private struct KeyboardTestInput: UIViewRepresentable {
    let input: UITextField
    func makeUIView(context: Context) -> UITextField { input }
    func updateUIView(_ uiView: UITextField, context: Context) {}
}
