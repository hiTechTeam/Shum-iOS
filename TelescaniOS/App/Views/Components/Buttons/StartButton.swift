import SwiftUI

struct RegistrationPrimaryButton: View {

    @Environment(\.colorScheme) private var colorScheme

    let title: String
    var isEnabled = true
    var accentColor: Color = .bl2
    var enabledForegroundColor: Color = .white
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
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(foregroundColor)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(backgroundColor)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 13,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

struct StartButton: View {

    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let accentColor: Color
    let onStart: () -> Void

    var body: some View {
        RegistrationPrimaryButton(
            title: title,
            accentColor: colorScheme == .dark ? accentColor : .white,
            enabledForegroundColor: colorScheme == .dark ? .white : accentColor,
            action: onStart
        )
        .accessibilityHint(Inc.Onboarding.continueHint.localized)
    }
}
