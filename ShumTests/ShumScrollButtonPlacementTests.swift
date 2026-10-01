import Combine
import SwiftUI
import Testing
import UIKit
@preconcurrency @testable import Shum

/// The scroll-to-bottom chevron keeps the same gap above the message capsule,
/// also when a line such as "add to contacts" is shown above the capsule.
@Suite("Scroll-to-bottom placement", .serialized)
@MainActor
struct ShumScrollButtonPlacementTests {
    @MainActor final class Probe: ObservableObject {
        @Published var atBottom = true
        @Published var capsuleInset: CGFloat = 8
        var chevron: CGRect = .zero
        var capsule: CGRect = .zero
    }

    /// Same structure as ShumConversationView's composer and chevron.
    struct Fixture: View {
        @ObservedObject var probe: Probe
        let showsLineAboveCapsule: Bool

        var body: some View {
            GeometryReader { geometry in
                ShumConversationTimeline(
                    items: (0..<100).map { ShumTimelineItem(id: "\($0)", revision: 0) },
                    storageKey: "test.chevron.\(showsLineAboveCapsule)", appearanceKey: "chevron", command: nil,
                    contentInsets: geometry.safeAreaInsets,
                    composer: AnyView(composer),
                    accessory: probe.atBottom ? nil : AnyView(chevron),
                    accessoryInset: probe.capsuleInset,
                    bottomChanged: { probe.atBottom = $0 }, tapped: {}
                ) { index, _ in Text("Message \(index)").frame(height: 44) }
                .ignoresSafeArea(.all, edges: .vertical)
            }
        }

        private var composer: some View {
            VStack(spacing: 8) {
                if showsLineAboveCapsule {
                    Text("Не в контактах · Добавить").font(.system(size: 13)).frame(minHeight: 28)
                }
                HStack {
                    Text("Сообщение").padding(.leading, 16).padding(.vertical, 12)
                    Spacer()
                    Circle().frame(width: 36, height: 36).padding(5)
                }
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.capsule = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("composer")).minY } action: {
                    probe.capsuleInset = $0
                }
            }
            .frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 8)
            .coordinateSpace(name: "composer")
        }

        private var chevron: some View {
            Button {} label: {
                Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
                    .frame(width: 40, height: 40).contentShape(Circle())
            }
            .buttonStyle(.plain)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.chevron = $0 }
        }
    }

    @Test(arguments: [false, true])
    func chevronSitsJustAboveTheCapsule(showsLineAboveCapsule: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.windowLevel = .alert + 1
        let probe = Probe()
        window.rootViewController = UIHostingController(rootView: Fixture(probe: probe, showsLineAboveCapsule: showsLineAboveCapsule))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            UserDefaults.standard.removeObject(forKey: "test.chevron.\(showsLineAboveCapsule)")
        }
        try await Task.sleep(for: .milliseconds(500))
        func table(in view: UIView) -> UITableView? {
            if let table = view as? UITableView { return table }
            return view.subviews.lazy.compactMap { table(in: $0) }.first
        }
        try #require(table(in: window)).setContentOffset(CGPoint(x: 0, y: 1500), animated: false)
        try await Task.sleep(for: .milliseconds(800))

        #expect(probe.chevron != .zero, "The chevron must appear after scrolling up")
        let gap = probe.capsule.minY - probe.chevron.maxY
        #expect(abs(gap - ShumTimelineController.accessoryGap) < 0.5,
                "Chevron is \(gap) pt above the capsule on iOS \(UIDevice.current.systemVersion)")
    }
}
