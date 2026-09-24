import SwiftUI
import Testing
@testable import Shum

@Suite("Chat capture boundaries")
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
}

private struct CaptureProbe: View {
    @Environment(\.shumCaptureProtectionEnabled) private var isProtected
    let report: (Bool) -> Void

    var body: some View {
        report(isProtected)
        return Color.clear.frame(width: 10, height: 10)
    }
}
