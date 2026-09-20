import SwiftUI

struct RegistrationPrimaryButton: View {

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shumThemePalette) private var palette

    let title: String
    var isEnabled = true
    var accentColor: Color? = nil
    var enabledForegroundColor: Color?
    let action: () -> Void

    private var foregroundColor: Color {
        guard !isEnabled else { return enabledForegroundColor ?? palette.accentForeground }

        return colorScheme == .dark
            ? .white.opacity(0.4)
            : .black.opacity(0.32)
    }

    private var backgroundColor: Color {
        guard !isEnabled else { return accentColor ?? palette.accent }

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
                .clipShape(Capsule())
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
            action: onStart
        )
        .accessibilityHint(Inc.Onboarding.continueHint.localized)
    }
}

struct ShumPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.shumThemePalette) private var palette

    private var foregroundColor: Color {
        if enabled { return palette.accentForeground }
        return colorScheme == .dark ? .white.opacity(0.4) : .black.opacity(0.32)
    }

    private var backgroundColor: Color {
        if enabled { return palette.accent }
        return colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.12)
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(backgroundColor, in: Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
