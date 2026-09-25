import Combine
import SwiftUI
import UIKit

private enum ShumCaptureBackend {
    case secureTextContainer, redaction

    static var current: Self {
        #if DEBUG && targetEnvironment(simulator)
        // Exercise the iOS 16–17 backend on locally available newer runtimes.
        if ProcessInfo.processInfo.arguments.contains("-ShumLegacyCapture") { return .secureTextContainer }
        #endif
        if #available(iOS 18.0, *) { return .redaction }
        return .secureTextContainer
    }
}

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
        .accessibilityLabel("Содержимое Shum скрыто".localized)
    }
}

/// Keeps one placeholder behind the protected surface. Both capture backends
/// rely on undocumented system behavior and require device regression checks.
struct ShumCaptureProtectedContainer<Content: View>: View {
    @Environment(\.self) private var environment
    private let content: Content
    let isEnabled: Bool
    let showsCover: Bool
    let protectsSystemChrome: Bool

    init(isEnabled: Bool = true, showsCover: Bool = true,
         protectsSystemChrome: Bool = false, @ViewBuilder content: () -> Content) {
        self.isEnabled = isEnabled
        self.showsCover = showsCover
        self.protectsSystemChrome = protectsSystemChrome
        self.content = content()
    }

    var body: some View {
        ZStack {
            if showsCover && (isEnabled || usesSecureTextContainer) {
                ShumPrivacyCover()
            }

            protectedContent

            if isEnabled && showsCover {
                ShumCapturePrivacyOverlay()
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var protectedContent: some View {
        if usesSecureTextContainer {
            // Host the complete NavigationStack, not individual rows. This
            // preserves toolbar preferences, sheets, focus and navigation state.
            // Keep the same host when protection changes on a public route.
            ShumSecureCaptureHost(isEnabled: isEnabled) {
                captureContent.shumHiddenFromSystemCapture(isEnabled)
                    .environment(\.self, environment)
                    .environment(\.shumCaptureProtectionEnabled, isEnabled)
            }
        } else {
            captureContent.shumHiddenFromSystemCapture(isEnabled)
        }
    }

    private var captureContent: some View {
        content
            .background {
                if isEnabled { ShumThemeCanvas().ignoresSafeArea() }
            }
            .environment(\.shumCaptureProtectionEnabled, isEnabled)
    }

    private var usesSecureTextContainer: Bool {
        // Re-parenting TabView into the secure text canvas loses the physical
        // device's top and bottom safe areas. Protect its UIKit chrome with
        // native redaction while each chat stack keeps its own capture host.
        !protectsSystemChrome && ShumCaptureBackend.current == .secureTextContainer
    }
}

private struct ShumCaptureProtectionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var shumCaptureProtectionEnabled: Bool {
        get { self[ShumCaptureProtectionKey.self] }
        set { self[ShumCaptureProtectionKey.self] = newValue }
    }
}

extension View {
    func shumProtectFromCapture(_ isEnabled: Bool = true, showsCover: Bool = true,
                                protectsSystemChrome: Bool = false) -> some View {
        ShumCaptureProtectedContainer(isEnabled: isEnabled, showsCover: showsCover,
                                      protectsSystemChrome: protectsSystemChrome) { self }
    }

    /// Only opts this presentation out. A QR sheet must never disable protection
    /// on the conversation or contact card still visible underneath it.
    func shumAllowsScreenshots() -> some View {
        shumHiddenFromSystemCapture(false)
            .environment(\.shumCaptureProtectionEnabled, false)
    }
}

extension View {
    @ViewBuilder
    func shumHiddenFromSystemCapture(_ isEnabled: Bool) -> some View {
        if #available(iOS 18.0, *), ShumCaptureBackend.current == .redaction {
            modifier(ShumCaptureRedactionModifier(isEnabled: isEnabled))
        } else {
            // iOS 16–17 protection belongs to the enclosing secure host.
            // Wrapping this leaf would break NavigationStack preferences.
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

/// Covers a protected chat surface during recording, mirroring or screen sharing.
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
