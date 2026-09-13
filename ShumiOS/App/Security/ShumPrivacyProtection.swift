import Combine
import SwiftUI
import UIKit

/// A neutral surface used for system snapshots and while the scene is captured.
/// It intentionally contains no profile, notification, or connection state.
struct ShumPrivacyCover: View {
    var body: some View {
        ZStack {
            Color("ls-Background")

            Image.shumLogo
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(width: 92, height: 92)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Содержимое Shum скрыто")
    }
}

/// Keeps the live hierarchy unchanged on screen while replacing it with a
/// neutral blurred surface in screenshots and recordings. Unlike the former
/// secure-text-field container, this does not re-parent SwiftUI/UIKit views, so
/// symbols, Canvas drawings, links and presentation controllers render normally.
struct ShumCaptureProtectedContainer<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            ShumPrivacyCover()

            ZStack {
                Color("ls-Background").ignoresSafeArea()
                content
            }
            .shumHiddenFromSystemCapture()
        }
    }
}

private extension View {
    @ViewBuilder
    func shumHiddenFromSystemCapture() -> some View {
        if #available(iOS 18.0, *) {
            modifier(ShumCaptureRedactionModifier())
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
private struct ShumCaptureRedactionModifier: ViewModifier {
    private static let captureProhibited = RedactionReasons(rawValue: 1 << 3)

    func body(content: Content) -> some View {
        content
            .privacySensitive(false)
            .transformEnvironment(\.redactionReasons) { reasons in
                reasons.insert(Self.captureProhibited)
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
