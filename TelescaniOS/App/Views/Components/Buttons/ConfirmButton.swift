import SwiftUI

struct ConfirmButton: View {

    @Binding var codeStatus: Bool?

    var onConfirm: () -> Void

    private let title: String = Inc.Onboarding.confirmButton.localized
    private let buttonWidth: CGFloat = 360
    private let paddingBottom: CGFloat = 16

    private var isEnabled: Bool {
        codeStatus == true
    }

    var body: some View {
        RegistrationPrimaryButton(
            title: title,
            isEnabled: isEnabled,
            action: onConfirm
        )
        .frame(maxWidth: buttonWidth)
        .padding(.bottom, paddingBottom)
    }
}
