import SwiftUI

struct NextButton: View {

    @Binding var codeStatus: Bool?

    var onNext: () -> Void

    private let title: String = Inc.Profile.linkTelegram.localized
    private let buttonWidth: CGFloat = 360
    private let paddingBottom: CGFloat = 16

    private var isEnabled: Bool {
        codeStatus == true
    }

    var body: some View {
        RegistrationPrimaryButton(
            title: title,
            isEnabled: isEnabled,
            action: onNext
        )
        .frame(maxWidth: buttonWidth)
        .padding(.horizontal, 20)
        .padding(.bottom, paddingBottom)
    }
}
