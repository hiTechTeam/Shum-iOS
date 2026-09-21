import Combine
import SwiftUI
import UIKit

/// A neutral surface used for system snapshots and while the scene is captured.
/// It intentionally contains no profile, notification, or connection state.
struct ShumPrivacyCover: View {
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        ZStack {
            palette.privacySurface

            ShumLogoMark(color: palette.accent)
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
    @State private var allowsScreenshots = false

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            ShumPrivacyCover()

            ZStack {
                ShumThemeCanvas().ignoresSafeArea()
                content
            }
            .shumHiddenFromSystemCapture(!allowsScreenshots)
        }
        .onPreferenceChange(ShumScreenshotAllowancePreferenceKey.self) {
            allowsScreenshots = $0
        }
    }
}

private struct ShumScreenshotAllowancePreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Opts public, shareable content out of screenshot redaction locally.
    /// The surrounding navigation, presented screens, recording cover and
    /// app-switcher cover retain their existing protection.
    @ViewBuilder
    func shumAllowsScreenshots() -> some View {
        if #available(iOS 18.0, *) {
            transformEnvironment(\.redactionReasons) { reasons in
                reasons.remove(ShumCaptureRedactionModifier.captureProhibited)
            }
            .preference(key: ShumScreenshotAllowancePreferenceKey.self, value: true)
        } else {
            preference(key: ShumScreenshotAllowancePreferenceKey.self, value: true)
        }
    }
}

private extension View {
    @ViewBuilder
    func shumHiddenFromSystemCapture(_ isEnabled: Bool) -> some View {
        if #available(iOS 18.0, *) {
            modifier(ShumCaptureRedactionModifier(isEnabled: isEnabled))
        } else {
            self
        }
    }
}

@available(iOS 18.0, *)
private struct ShumCaptureRedactionModifier: ViewModifier {
    static let captureProhibited = RedactionReasons(rawValue: 1 << 3)
    let isEnabled: Bool

    func body(content: Content) -> some View {
        content
            .privacySensitive(false)
            .transformEnvironment(\.redactionReasons) { reasons in
                if isEnabled {
                    reasons.insert(Self.captureProhibited)
                } else {
                    reasons.remove(Self.captureProhibited)
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
