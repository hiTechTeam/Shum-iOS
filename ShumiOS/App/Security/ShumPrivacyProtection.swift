import Combine
import SwiftUI
import UIKit

/// A neutral surface used for system snapshots and while the scene is captured.
/// It intentionally contains no profile, notification, or connection state.
struct ShumPrivacyCover: View {
    var body: some View {
        ZStack {
            Color("ls-Background")

            ShumPixelPrivacyGesture()
                .foregroundStyle(.white)
                .frame(width: 126, height: 168)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Содержимое Shum скрыто")
    }
}

/// A deliberately low-resolution hand used only on privacy covers. Drawing the
/// silhouette in SwiftUI keeps it crisp at every scale and avoids affecting the
/// app's asset rendering, which must remain outside secure UIKit containers.
private struct ShumPixelPrivacyGesture: View {
    private let rows = [
        "........####........",
        ".......######.......",
        ".......######.......",
        ".......######.......",
        ".......######.......",
        ".......######.......",
        ".......######.......",
        ".......######.......",
        ".......######.......",
        "...####.######.####..",
        "..#####.######.#####.",
        "..##################.",
        "..##################.",
        "..##################.",
        "...################..",
        "....###############..",
        "....##############...",
        ".....#############...",
        ".....############....",
        "......###########....",
        "......###########....",
        "......###########....",
        "......###########....",
        "......###########....",
        ".....#############...",
        ".....#############..."
    ]

    var body: some View {
        GeometryReader { proxy in
            let columns = rows.map(\.count).max() ?? 1
            let unit = floor(min(
                proxy.size.width / CGFloat(columns),
                proxy.size.height / CGFloat(rows.count)
            ))
            let drawingSize = CGSize(
                width: CGFloat(columns) * unit,
                height: CGFloat(rows.count) * unit
            )
            let origin = CGPoint(
                x: (proxy.size.width - drawingSize.width) / 2,
                y: (proxy.size.height - drawingSize.height) / 2
            )

            Canvas(rendersAsynchronously: false) { context, _ in
                for (y, row) in rows.enumerated() {
                    for (x, character) in row.enumerated() where character == "#" {
                        context.fill(
                            Path(CGRect(
                                x: origin.x + CGFloat(x) * unit,
                                y: origin.y + CGFloat(y) * unit,
                                width: unit,
                                height: unit
                            )),
                            with: .foreground
                        )
                    }
                }
            }
        }
    }
}

/// Covers the app during recording, mirroring, AirPlay, or remote screen sharing.
/// iOS 17 and newer expose capture state directly to SwiftUI.
struct ShumCapturePrivacyOverlay: View {
    var body: some View {
        if #available(iOS 17.0, *) {
            ShumModernCapturePrivacyOverlay()
        } else {
            ShumLegacyCapturePrivacyOverlay()
        }
    }
}

@available(iOS 17.0, *)
private struct ShumModernCapturePrivacyOverlay: View {
    @Environment(\.isSceneCaptured) private var isSceneCaptured

    var body: some View {
        if isSceneCaptured {
            ShumPrivacyCover()
        }
    }
}

private struct ShumLegacyCapturePrivacyOverlay: View {
    @StateObject private var monitor = ShumLegacyCaptureMonitor()

    var body: some View {
        if monitor.isCaptured {
            ShumPrivacyCover()
        }
    }
}

@MainActor
private final class ShumLegacyCaptureMonitor: ObservableObject {
    @Published private(set) var isCaptured: Bool

    private var observer: NSObjectProtocol?

    init(notificationCenter: NotificationCenter = .default) {
        isCaptured = Self.currentCaptureState
        observer = notificationCenter.addObserver(
            forName: UIScreen.capturedDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isCaptured = Self.currentCaptureState
            }
        }
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private static var currentCaptureState: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .contains { $0.screen.isCaptured }
    }
}
