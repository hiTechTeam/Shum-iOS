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
            AnyView(Text("Message \(index)").frame(width: width, height: (index % 3 == 0 ? 140 : 44) * 390 / max(1, width)))
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
        // A width change reflows rows; it must still preserve the message being
        // read rather than treating the height difference as keyboard movement.
        controller.view.frame.size.width = 300
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let reflowedOffset = table.rectForRow(at: anchor).minY - table.contentOffset.y - table.contentInset.top
        #expect(abs(reflowedOffset + 20) < 2)
        window.isHidden = true
    }

    @Test(arguments: [3, 8, 12, 100])
    func shortAndLongHistoryMoveInSyncWithKeyboard(rowCount: Int) async throws {
        try await checkKeyboardMotion(rowCount: rowCount, readingHistory: false)
    }

    @Test func readingOlderMessagesMovesWithKeyboardWithoutJumpingToBottom() async throws {
        try await checkKeyboardMotion(rowCount: 100, readingHistory: true)
    }

    private func checkKeyboardMotion(rowCount: Int, readingHistory: Bool) async throws {
        let key = "test.timeline.keyboard.\(UUID())"
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: (originalKeyWindow?.windowLevel.rawValue ?? 0) + 1)
        let input = UITextField()
        input.placeholder = "Message"
        let host = UIHostingController(rootView: KeyboardTimelineFixture(key: key, input: input, rowCount: rowCount))
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
        if readingHistory {
            table.setContentOffset(CGPoint(x: 0, y: 400), animated: false)
            table.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
        let readingAnchor = table.indexPathsForVisibleRows?.sorted().dropFirst(5).first
        func positions() -> (input: CGFloat, messages: CGFloat) {
            let target = window.layer.presentation() ?? window.layer
            let inputLayer = input.layer.presentation() ?? input.layer
            let tableLayer = table.layer.presentation() ?? table.layer
            let inputTop = inputLayer.convert(CGPoint(x: 0, y: inputLayer.bounds.minY), to: target).y
            let marker = readingHistory ? table.rectForRow(at: readingAnchor!).minY : table.contentSize.height
            let messageBottom = tableLayer.convert(CGPoint(x: 0, y: marker), to: target).y
            return (inputTop, messageBottom)
        }
        let resting = positions()
        let initialInputTop = input.convert(input.bounds, to: window).minY
        for cycle in 0..<2 {
            for opening in [true, false] {
                let start = positions()
                if opening { #expect(input.becomeFirstResponder()) }
                else { #expect(input.resignFirstResponder()) }
                var samples: [(input: CGFloat, messages: CGFloat)] = []
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(16))
                    samples.append(positions())
                }
                let end = positions()
                // UIKit's keyboard transaction must drive the whole movement.
                // A partially fitting history moves only by its overflow; a
                // fully fitting history stays at the top throughout.
                let travel = end.input - start.input
                let messageTravel = end.messages - start.messages
                let errors = samples.map { sample in
                    let progress = abs(travel) > 1 ? (sample.input - start.input) / travel : 0
                    return sample.messages - (start.messages + messageTravel * progress)
                }
                if readingHistory {
                    #expect(abs(messageTravel - travel) < 2)
                } else {
                    #expect(abs(end.messages - min(resting.messages, end.input - 18)) < 2)
                }
                let displacement = initialInputTop - input.convert(input.bounds, to: window).minY
                if opening {
                    #expect(displacement > 100, "This check requires a visible software keyboard")
                } else {
                    #expect(abs(displacement) < 2)
                }
                let maximumDrift = errors.map { abs($0) }.max() ?? 0
                #expect(maximumDrift < 4,
                        "Cycle \(cycle), opening \(opening): gap drifted by \(maximumDrift) points: \(errors)")
            }
        }
        if rowCount == 100, !readingHistory {
            // Reverse a keyboard transition before it finishes. There must be
            // no delayed final-offset correction from the interrupted opening.
            #expect(input.becomeFirstResponder())
            try await Task.sleep(for: .milliseconds(80))
            #expect(input.resignFirstResponder())
            var drift: CGFloat = 0
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(16))
                let current = positions()
                drift = max(drift, abs(current.input - current.messages - 18))
            }
            #expect(drift < 4, "Interrupted keyboard transition drifted by \(drift) points")
        }
    }
}

private struct KeyboardTimelineFixture: View {
    let key: String
    let input: UITextField
    let rowCount: Int
    var body: some View {
        GeometryReader { geometry in
            ShumConversationTimeline(
                items: (0..<rowCount).map { ShumTimelineItem(id: "\($0)", revision: 0) },
                storageKey: key, appearanceKey: "test", command: nil,
                contentInsets: geometry.safeAreaInsets, bottomChanged: { _ in }, tapped: {}
            ) { index, width in
                Text("Message \(index)").frame(width: width, height: CGFloat(44 + (index % 3) * 20))
            }
            .ignoresSafeArea(.all, edges: .vertical)
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
