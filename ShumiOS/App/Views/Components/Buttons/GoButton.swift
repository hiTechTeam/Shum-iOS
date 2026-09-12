import SwiftUI

struct GoButton: View {

    @Binding var isScanning: Bool

    var onGo: () -> Void

    private let title: String = Inc.Onboarding.goStart.localized
    private let buttonWidth: CGFloat = 360
    private let paddingBottom: CGFloat = 16

    private var isEnabled: Bool {
        isScanning
    }

    var body: some View {
        RegistrationPrimaryButton(
            title: title,
            isEnabled: isEnabled,
            action: onGo
        )
        .frame(maxWidth: buttonWidth)
        .padding(.horizontal, 20)
        .padding(.bottom, paddingBottom)
    }
}
