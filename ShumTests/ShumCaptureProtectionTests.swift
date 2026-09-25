import SwiftUI
import Testing
@testable import Shum

@Suite("Chat capture boundaries", .serialized)
@MainActor
struct ShumCaptureProtectionTests {
    @Test func qrAllowanceDoesNotChangeProtectedSiblings() {
        var values: [String: Bool] = [:]
        let host = UIHostingController(rootView:
            ShumCaptureProtectedContainer {
                VStack {
                    CaptureProbe { values["chat"] = $0 }
                    CaptureProbe { values["qr"] = $0 }
                        .shumAllowsScreenshots()
                    CaptureProbe { values["card"] = $0 }
                }
            }
        )
        _ = host.sizeThatFits(in: CGSize(width: 390, height: 844))

        #expect(values["chat"] == true)
        #expect(values["card"] == true)
        #expect(values["qr"] == false)
    }

    @Test func publicScreensDoNotInheritChatProtection() {
        var protected: Bool?
        let host = UIHostingController(rootView:
            ShumCaptureProtectedContainer(isEnabled: false) {
                CaptureProbe { protected = $0 }
            }
        )
        _ = host.sizeThatFits(in: CGSize(width: 390, height: 844))
        #expect(protected == false)
    }

    @Test func legacyHostProtectsTheEntireContentAndKeepsControllerContainment() throws {
        let controller = ShumSecureCaptureController(content: Text("Private message"), isEnabled: true)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        controller.view.layoutIfNeeded()

        let canvas = try #require(controller.captureView.secureCanvas)
        #expect(controller.captureView.isSecureTextEntry)
        #expect(controller.hostingController.parent === controller)
        #expect(controller.hostingController.view.isDescendant(of: canvas))
        #expect(!controller.hostingController.view.isHidden)
        #expect(canvas.bounds.size == CGSize(width: 390, height: 844))
        #expect(controller.hostingController.view.bounds.size == canvas.bounds.size)
    }

    @Test func legacyHostFailsClosedWhenSystemCanvasIsUnavailable() {
        let container = ShumSecureCaptureView(canvasResolver: { _ in nil })
        let content = UIView()
        container.install(content)
        #expect(content.isHidden)

        container.setProtectionEnabled(false)
        #expect(!content.isHidden)
        container.setProtectionEnabled(true)
        #expect(content.isHidden)
    }

    @Test func changingCapturePolicyPreservesTheHostAndProtectsOutgoingChat() {
        let controller = ShumSecureCaptureController(content: Text("Chat"), isEnabled: true)
        controller.loadViewIfNeeded()
        let host = controller.hostingController
        let canvas = controller.captureView.secureCanvas

        controller.update(content: Text("Contacts"), isEnabled: false)
        #expect(controller.captureView.isSecureTextEntry)
        controller.update(content: Text("Chat again"), isEnabled: true)

        #expect(controller.hostingController === host)
        #expect(controller.captureView.secureCanvas === canvas)
        #expect(controller.captureView.isSecureTextEntry)
    }

    @Test func publicRouteStartsUnprotectedAndCanBecomeProtected() {
        let controller = ShumSecureCaptureController(content: Text("QR"), isEnabled: false)
        controller.loadViewIfNeeded()
        #expect(!controller.captureView.isSecureTextEntry)

        controller.update(content: Text("Chat"), isEnabled: true)
        #expect(controller.captureView.isSecureTextEntry)
        #expect(!controller.hostingController.view.isHidden)
    }

    @Test func leavingChatReleasesProtectionAfterTransitionGracePeriod() async throws {
        let controller = ShumSecureCaptureController(content: Text("Chat"), isEnabled: true)
        controller.loadViewIfNeeded()
        controller.update(content: Text("QR"), isEnabled: false)
        #expect(controller.captureView.isSecureTextEntry)
        try await Task.sleep(nanoseconds: 750_000_000)
        #expect(!controller.captureView.isSecureTextEntry)
        #expect(!controller.hostingController.view.isHidden)
        let canvas = try #require(controller.captureView.secureCanvas)
        #expect(controller.hostingController.view.isDescendant(of: canvas))
    }

    @Test func returningToChatCancelsPendingCaptureAllowance() async throws {
        let controller = ShumSecureCaptureController(content: Text("Chat"), isEnabled: true)
        controller.loadViewIfNeeded()
        controller.update(content: Text("QR"), isEnabled: false)
        controller.update(content: Text("Chat"), isEnabled: true)
        try await Task.sleep(nanoseconds: 750_000_000)
        #expect(controller.captureView.isSecureTextEntry)
    }

    @Test func legacyHostForwardsCaptureBoundaryToItsContent() {
        var values: [String: Bool] = [:]
        let host = ShumSecureCaptureController(content:
            VStack {
                CaptureProbe { values["chat"] = $0 }
                CaptureProbe { values["qr"] = $0 }.shumAllowsScreenshots()
                CaptureProbe { values["chatAfterQR"] = $0 }
            }.environment(\.shumCaptureProtectionEnabled, true),
            isEnabled: true
        )
        host.loadViewIfNeeded()
        _ = host.hostingController.sizeThatFits(in: CGSize(width: 390, height: 844))

        #expect(values["chat"] == true)
        #expect(values["qr"] == false)
        #expect(values["chatAfterQR"] == true)
        #expect(host.captureView.isSecureTextEntry)
    }

    @Test func qrPresentationIsOutsideLegacyCanvasWithoutDisablingChat() async throws {
        var values: [String: Bool] = [:]
        let root = UIHostingController(rootView:
            ShumSecureCaptureHost(isEnabled: true) {
                CaptureProbe { values["chat"] = $0 }
                    .sheet(isPresented: .constant(true)) {
                        CaptureProbe { values["qr"] = $0 }
                            .shumAllowsScreenshots()
                    }
                    .environment(\.shumCaptureProtectionEnabled, true)
            }
        )
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.view.layoutIfNeeded()
        defer {
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            originalKeyWindow?.makeKey()
        }
        try await Task.sleep(nanoseconds: 700_000_000)

        let canvas = try #require(secureCanvas(in: root))
        let presentation = try #require(presentedController(in: root))
        #expect(!presentation.view.isDescendant(of: canvas))
        let field = try #require(canvas.superview as? UITextField)
        #expect(field.isSecureTextEntry)
        #expect(values["chat"] == true)
        #expect(values["qr"] == false)
    }

    private func presentedController(in controller: UIViewController) -> UIViewController? {
        if let presented = controller.presentedViewController { return presented }
        return controller.children.lazy.compactMap { presentedController(in: $0) }.first
    }

    private func secureCanvas(in controller: UIViewController) -> UIView? {
        if let canvas = ShumSecureCaptureView.findCanvas(in: controller.view) { return canvas }
        return controller.children.lazy.compactMap { secureCanvas(in: $0) }.first
    }
}

private struct CaptureProbe: View {
    @Environment(\.shumCaptureProtectionEnabled) private var isProtected
    let report: (Bool) -> Void

    var body: some View {
        report(isProtected)
        return Color.clear.frame(width: 10, height: 10)
    }
}
