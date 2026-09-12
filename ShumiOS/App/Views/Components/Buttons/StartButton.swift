import SwiftUI

struct RegistrationPrimaryButton: View {

    @Environment(\.colorScheme) private var colorScheme

    let title: String
    var isEnabled = true
    var accentColor: Color = .accentColor
    var enabledForegroundColor: Color = .black
    let action: () -> Void

    private var foregroundColor: Color {
        guard !isEnabled else { return enabledForegroundColor }

        return colorScheme == .dark
            ? .white.opacity(0.4)
            : .black.opacity(0.32)
    }

    private var backgroundColor: Color {
        guard !isEnabled else { return accentColor }

        return colorScheme == .dark
            ? .white.opacity(0.16)
            : .black.opacity(0.12)
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

struct StartButton: View {

    let title: String
    let accentColor: Color
    let onStart: () -> Void

    var body: some View {
        RegistrationPrimaryButton(
            title: title,
            accentColor: accentColor,
            enabledForegroundColor: .black,
            action: onStart
        )
        .accessibilityHint(Inc.Onboarding.continueHint.localized)
    }
}

struct ShumPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .semibold))
            .foregroundStyle(enabled ? Color.black : Color.secondary)
            .padding(.horizontal, 20).frame(minHeight: 50)
            .background(enabled ? Color.accentColor : Color.secondary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
