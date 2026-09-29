import Combine
import SwiftUI
import Testing
import UIKit
@testable import Shum

/// Frame-by-frame measurements of the chat moving with the software keyboard.
/// Every transition must keep the history glued to the composer, never uncover
/// an empty strip inside the chat, and finish without a late correction.
@Suite("Chat keyboard motion", .serialized)
@MainActor
struct ShumKeyboardMotionTests {
    @Test(arguments: [3, 12, 100])
    func historyFollowsKeyboard(rowCount: Int) async throws {
        try await measure(rowCount: rowCount, readingHistory: false)
    }

    @Test func readingHistoryFollowsKeyboard() async throws {
        try await measure(rowCount: 100, readingHistory: true)
    }

    /// The composer is hosted by the timeline controller, while its focus state
    /// belongs to the conversation screen. Tapping the history, the protection
    /// banner or a photo must still close the keyboard through that state.
    @Test func screenFocusStateControlsHostedComposer() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: (originalKeyWindow?.windowLevel.rawValue ?? 0) + 1)
        let probe = FocusProbe()
        let key = "test.keyboard.focus.\(UUID())"
        window.rootViewController = UIHostingController(rootView: FocusFixture(probe: probe, key: key))
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKey()
            UserDefaults.standard.removeObject(forKey: key)
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(Self.firstResponder(in: window) == nil)

        probe.requested = true
        try await Task.sleep(for: .milliseconds(800))
        #expect(Self.firstResponder(in: window) != nil, "Focusing from the screen must open the keyboard")

        probe.requested = false
        try await Task.sleep(for: .milliseconds(800))
        #expect(Self.firstResponder(in: window) == nil, "Unfocusing from the screen must close the keyboard")
    }

    /// The chevron appears once the reader leaves the bottom. Tapping it must
    /// land exactly on the last message, even though the button disappears
    /// while the history is still scrolling.
    @Test func scrollToBottomButtonReachesLastMessage() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = UIWindow.Level(rawValue: (originalKeyWindow?.windowLevel.rawValue ?? 0) + 1)
        let probe = ScrollProbe()
        let input = UITextField()
        let key = "test.keyboard.scroll.\(UUID())"
        window.rootViewController = UIHostingController(rootView: ScrollButtonFixture(probe: probe, input: input, key: key))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKey()
            UserDefaults.standard.removeObject(forKey: key)
        }
        try await Task.sleep(for: .milliseconds(400))
        let table = try #require(Self.findTable(in: window))
        for attempt in 0..<3 {
            table.setContentOffset(CGPoint(x: 0, y: 1500 + CGFloat(attempt) * 700), animated: false)
            try await Task.sleep(for: .milliseconds(400))
            #expect(probe.buttonVisible, "The chevron must appear after scrolling up")

            probe.command = ShumTimelineCommand(target: .bottom)
            try await Task.sleep(for: .milliseconds(1500))
            let last = IndexPath(row: table.numberOfRows(inSection: 0) - 1, section: 0)
            let lastBottom = table.convert(table.rectForRow(at: last), to: window).maxY
            let inputTop = input.convert(input.bounds, to: window).minY
            let distance = table.contentSize.height + table.contentInset.bottom
                - table.bounds.height - table.contentOffset.y
            print("SCROLL iOS \(UIDevice.current.systemVersion) attempt=\(attempt) "
                  + String(format: "gap=%.1f distanceFromEnd=%.1f", Double(inputTop - lastBottom), Double(distance)))
            #expect(abs(distance) < 1, "History stopped \(distance) pt before its end")
            #expect(abs(inputTop - lastBottom - KeyboardStage.composerGap) < 1,
                    "Last message must sit \(KeyboardStage.composerGap) pt above the composer")
            #expect(!probe.buttonVisible, "The chevron must hide at the bottom")
        }
    }

    private static func findTable(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }

    private static func firstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        return view.subviews.lazy.compactMap { firstResponder(in: $0) }.first
    }

    /// Slow open/close cycles for a screen recording of the simulator.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHUM_KEYBOARD_VIDEO"] == "1"))
    func keyboardDemoForRecording() async throws {
        let stage = try await KeyboardStage.make(rowCount: 100)
        defer { stage.tearDown() }
        try await Task.sleep(for: .seconds(1))
        for _ in 0..<3 {
            _ = stage.input.becomeFirstResponder()
            try await Task.sleep(for: .seconds(1.2))
            _ = stage.input.resignFirstResponder()
            try await Task.sleep(for: .seconds(1.2))
        }
    }

    private func measure(rowCount: Int, readingHistory: Bool) async throws {
        let stage = try await KeyboardStage.make(rowCount: rowCount)
        defer { stage.tearDown() }
        if readingHistory { try await stage.scrollHistory(to: 400) }
        let anchor = readingHistory ? stage.readingAnchor() : nil
        for opening in [true, false, true, false] {
            let report = await stage.transition(opening: opening, anchor: anchor, checkCoverage: rowCount >= 100)
            print("KEYBOARD iOS \(UIDevice.current.systemVersion) rows=\(rowCount) reading=\(readingHistory) "
                  + "\(opening ? "open " : "close") \(report)")
            #expect(report.keyboardTravel > 100, "This check requires a visible software keyboard")
            #expect(report.drift < 4, "History drifted from the composer by \(report.drift) pt")
            #expect(report.blank < 2, "An empty strip of \(report.blank) pt appeared inside the chat")
            #expect(report.snap < 1, "History moved by \(report.snap) pt while the keyboard stood still")
        }
    }
}

private struct KeyboardSample {
    /// Top of the text field in window coordinates.
    let input: CGFloat
    /// Bottom of the history, or the top of the anchored row while reading.
    let marker: CGFloat
    /// Where the history would end if it were not pushed up by the composer.
    let natural: CGFloat
    /// Largest empty vertical span between the top safe area and the composer.
    let blank: CGFloat
}

private struct KeyboardReport: CustomStringConvertible {
    var keyboardTravel: CGFloat = 0
    var historyTravel: CGFloat = 0
    var drift: CGFloat = 0
    var blank: CGFloat = 0
    var snap: CGFloat = 0

    var description: String {
        String(format: "keyboard=%.0f history=%.0f drift=%.1f blank=%.1f snap=%.1f",
               Double(keyboardTravel), Double(historyTravel), Double(drift), Double(blank), Double(snap))
    }
}

@MainActor
private final class KeyboardStage {
    /// Space between the text field and the last message: the timeline's
    /// 10 pt gap plus the composer's 8 pt top padding.
    static let composerGap: CGFloat = 18

    let input = UITextField()
    private let window: UIWindow
    private let originalKeyWindow: UIWindow?
    private let key = "test.keyboard.motion.\(UUID())"
    private var table: UITableView!

    private init(scene: UIWindowScene) {
        originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
    }

    static func make(rowCount: Int) async throws -> KeyboardStage {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let stage = KeyboardStage(scene: scene)
        try await stage.show(rowCount: rowCount)
        return stage
    }

    private func show(rowCount: Int) async throws {
        input.placeholder = "Message"
        input.borderStyle = .roundedRect
        input.backgroundColor = UIColor(white: 0.18, alpha: 1)
        window.frame = window.windowScene?.coordinateSpace.bounds ?? UIScreen.main.bounds
        window.windowLevel = UIWindow.Level(rawValue: (originalKeyWindow?.windowLevel.rawValue ?? 0) + 1)
        window.overrideUserInterfaceStyle = .dark
        let host = UIHostingController(rootView: KeyboardChatFixture(key: key, input: input, rowCount: rowCount))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        table = try #require(Self.findTable(in: host.view))
    }

    func tearDown() {
        input.resignFirstResponder()
        window.isHidden = true
        window.rootViewController = nil
        originalKeyWindow?.makeKey()
        UserDefaults.standard.removeObject(forKey: key)
    }

    func scrollHistory(to offset: CGFloat) async throws {
        table.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        table.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
    }

    func readingAnchor() -> IndexPath? {
        table.indexPathsForVisibleRows?.sorted().dropFirst(5).first
    }

    func transition(opening: Bool, anchor: IndexPath?, checkCoverage: Bool) async -> KeyboardReport {
        let start = sample(anchor: anchor, checkCoverage: checkCoverage)
        if opening { _ = input.becomeFirstResponder() } else { _ = input.resignFirstResponder() }
        let samples = await FrameSampler().run(frames: 75) {
            self.sample(anchor: anchor, checkCoverage: checkCoverage)
        }
        guard let end = samples.last else { return KeyboardReport() }
        var report = KeyboardReport()
        report.keyboardTravel = abs(end.input - start.input)
        report.historyTravel = end.marker - start.marker
        for sample in samples {
            let expected = anchor == nil
                ? min(sample.natural, sample.input - Self.composerGap)
                : start.marker + (sample.input - start.input)
            report.drift = max(report.drift, abs(sample.marker - expected))
            report.blank = max(report.blank, sample.blank)
        }
        for (previous, next) in zip([start] + samples, samples) where abs(next.input - previous.input) < 0.3 {
            report.snap = max(report.snap, abs(next.marker - previous.marker))
        }
        return report
    }

    private func sample(anchor: IndexPath?, checkCoverage: Bool) -> KeyboardSample {
        let target = window.layer.presentation() ?? window.layer
        let inputLayer = input.layer.presentation() ?? input.layer
        let tableLayer = table.layer.presentation() ?? table.layer
        let inputTop = inputLayer.convert(CGPoint(x: 0, y: inputLayer.bounds.minY), to: target).y
        let markerY = anchor.map { table.rectForRow(at: $0).minY } ?? table.contentSize.height
        let marker = tableLayer.convert(CGPoint(x: 0, y: markerY), to: target).y
        let viewportTop = table.superview.map { $0.convert(CGPoint.zero, to: window).y } ?? 0
        let natural = viewportTop + table.contentInset.top + table.contentSize.height
        let blank = checkCoverage ? largestGap(above: inputTop - Self.composerGap - 2, in: target) : 0
        return KeyboardSample(input: inputTop, marker: marker, natural: natural, blank: blank)
    }

    /// Empty space inside the visible chat area, measured on what is actually
    /// on screen: presented cells, clipped by the presented table bounds.
    private func largestGap(above limit: CGFloat, in target: CALayer) -> CGFloat {
        let tableLayer = table.layer.presentation() ?? table.layer
        let visible = tableLayer.convert(tableLayer.bounds, to: target)
        let spans = table.subviews.compactMap { view -> (CGFloat, CGFloat)? in
            guard let cell = view as? UITableViewCell, !cell.isHidden, cell.alpha > 0.01 else { return nil }
            let layer = cell.layer.presentation() ?? cell.layer
            let frame = layer.convert(layer.bounds, to: target)
            let top = max(frame.minY, visible.minY), bottom = min(frame.maxY, visible.maxY)
            return bottom > top ? (top, bottom) : nil
        }.sorted { $0.0 < $1.0 }
        var covered = window.safeAreaInsets.top
        var largest: CGFloat = 0
        for (top, bottom) in spans where covered < limit {
            if top > covered { largest = max(largest, min(top, limit) - covered) }
            covered = max(covered, bottom)
        }
        if covered < limit { largest = max(largest, limit - covered) }
        return largest
    }

    private static func findTable(in view: UIView) -> UITableView? {
        if let table = view as? UITableView { return table }
        return view.subviews.lazy.compactMap { findTable(in: $0) }.first
    }
}

/// Samples once per display refresh, so every rendered frame is measured.
@MainActor
private final class FrameSampler: NSObject {
    private var link: CADisplayLink?
    private var remaining = 0
    private var body: () -> KeyboardSample = { KeyboardSample(input: 0, marker: 0, natural: 0, blank: 0) }
    private var samples: [KeyboardSample] = []
    private var continuation: CheckedContinuation<[KeyboardSample], Never>?

    func run(frames: Int, _ body: @escaping () -> KeyboardSample) async -> [KeyboardSample] {
        remaining = frames
        self.body = body
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick() {
        samples.append(body())
        remaining -= 1
        guard remaining <= 0 else { return }
        link?.invalidate()
        link = nil
        continuation?.resume(returning: samples)
        continuation = nil
    }
}

/// Mirrors ShumConversationView: a full-height timeline and the composer.
private struct KeyboardChatFixture: View {
    let key: String
    let input: UITextField
    let rowCount: Int

    var body: some View {
        GeometryReader { geometry in
            ShumConversationTimeline(
                items: (0..<rowCount).map { ShumTimelineItem(id: "\($0)", revision: 0) },
                storageKey: key, appearanceKey: "keyboard", command: nil,
                contentInsets: geometry.safeAreaInsets,
                composer: AnyView(FixtureComposer(input: input)),
                bottomChanged: { _ in }, tapped: {}
            ) { index, width in
                FixtureBubble(index: index, width: width)
            }
            .ignoresSafeArea(.all, edges: .vertical)
        }
        .background(Color(white: 0.06).ignoresSafeArea())
    }
}

@MainActor
private final class ScrollProbe: ObservableObject {
    @Published var command: ShumTimelineCommand?
    var buttonVisible = false
}

/// Mirrors ShumConversationView's chevron: shown while away from the bottom,
/// placed just above the composer.
private struct ScrollButtonFixture: View {
    @ObservedObject var probe: ScrollProbe
    let input: UITextField
    let key: String
    @State private var atBottom = true

    var body: some View {
        GeometryReader { geometry in
            ShumConversationTimeline(
                items: (0..<100).map { ShumTimelineItem(id: "\($0)", revision: 0) },
                storageKey: key, appearanceKey: "scroll", command: probe.command,
                contentInsets: geometry.safeAreaInsets,
                composer: AnyView(composer),
                accessory: atBottom ? nil : AnyView(Circle().fill(Color.green).frame(width: 40, height: 40)),
                bottomChanged: { bottom in
                    atBottom = bottom
                    probe.buttonVisible = !bottom
                }, tapped: {}
            ) { index, width in
                FixtureBubble(index: index, width: width)
            }
            .ignoresSafeArea(.all, edges: .vertical)
        }
    }

    private var composer: some View {
        FixtureInput(input: input)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
    }
}

@MainActor
private final class FocusProbe: ObservableObject {
    @Published var requested = false
}

/// Mirrors how ShumConversationView owns @FocusState for a composer that the
/// timeline hosts in its own UIHostingController.
private struct FocusFixture: View {
    @ObservedObject var probe: FocusProbe
    let key: String
    @FocusState private var focused: Bool
    @State private var text = ""

    var body: some View {
        GeometryReader { geometry in
            ShumConversationTimeline(
                items: (0..<20).map { ShumTimelineItem(id: "\($0)", revision: 0) },
                storageKey: key, appearanceKey: "focus", command: nil,
                contentInsets: geometry.safeAreaInsets,
                composer: AnyView(
                    TextField("Message", text: $text)
                        .focused($focused)
                        .frame(height: 46)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                ),
                bottomChanged: { _ in }, tapped: { focused = false }
            ) { index, width in
                FixtureBubble(index: index, width: width)
            }
            .ignoresSafeArea(.all, edges: .vertical)
        }
        .onChange(of: probe.requested) { focused = $0 }
    }
}

private struct FixtureComposer: View {
    let input: UITextField
    var body: some View {
        FixtureInput(input: input)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
    }
}

private struct FixtureInput: UIViewRepresentable {
    let input: UITextField
    func makeUIView(context: Context) -> UITextField { input }
    func updateUIView(_ uiView: UITextField, context: Context) {}
}

private struct FixtureBubble: View {
    let index: Int
    let width: CGFloat
    var body: some View {
        let mine = index % 2 == 0
        HStack(spacing: 0) {
            if mine { Spacer(minLength: 80) }
            Text("Message \(index)")
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 16)
                    .fill(mine ? Color(red: 0.2, green: 0.62, blue: 0.36) : Color(white: 0.28)))
            if !mine { Spacer(minLength: 80) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .frame(width: width, height: CGFloat(44 + (index % 3) * 20))
    }
}
