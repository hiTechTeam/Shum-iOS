import SwiftUI

struct Welcome: View {

    @Environment(\.colorScheme) private var colorScheme
    @State private var showHowItWorks = false

    private let referenceWidth: CGFloat = 390
    private let accentColor = Color(
        red: 10 / 255,
        green: 132 / 255,
        blue: 255 / 255
    )

    private var backgroundColor: Color {
        Color("ls-Background")
    }

    private let lightCircleColors: [Color] = [
        Color(red: 248 / 255, green: 248 / 255, blue: 250 / 255),
        Color(red: 243 / 255, green: 244 / 255, blue: 246 / 255),
        Color(red: 237 / 255, green: 239 / 255, blue: 242 / 255)
    ]

    private let darkCircleColors: [Color] = [
        Color(red: 20 / 255, green: 72 / 255, blue: 120 / 255),
        Color(red: 22 / 255, green: 44 / 255, blue: 67 / 255),
        Color(red: 24 / 255, green: 29 / 255, blue: 35 / 255)
    ]

    private var privacyPolicyURL: URL {
        URL(string: Links.privacyPolicy)!
    }

    private var termsOfServiceURL: URL {
        URL(string: Links.termsOfService)!
    }

    private func scale(for width: CGFloat) -> CGFloat {
        min(max(width / referenceWidth, 0.84), 1.12)
    }

    private func backgroundCircle(
        size: CGSize,
        scale: CGFloat
    ) -> some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? darkCircleColors
                        : lightCircleColors,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 940 * scale, height: 940 * scale)
            .position(
                x: size.width * 0.19,
                y: size.height * 0.18
            )
            .accessibilityHidden(true)
    }

    private func legalText(scale: CGFloat) -> AttributedString {
        let privacyTitle = Inc.Onboarding.privacyPolicy.localized
        let termsTitle = Inc.Onboarding.termsOfService.localized
        let content = String(
            format: Inc.Onboarding.legalAgreement.localized,
            privacyTitle,
            termsTitle
        )
        var text = AttributedString(content)

        text.foregroundColor = Color.secondary
        text.font = .system(size: 12 * scale, weight: .regular)

        if let privacyRange = text.range(of: privacyTitle) {
            text[privacyRange].link = privacyPolicyURL
            text[privacyRange].foregroundColor = accentColor
            text[privacyRange].font = .system(
                size: 12 * scale,
                weight: .regular
            )
        }

        if let termsRange = text.range(of: termsTitle) {
            text[termsRange].link = termsOfServiceURL
            text[termsRange].foregroundColor = accentColor
            text[termsRange].font = .system(
                size: 12 * scale,
                weight: .regular
            )
        }

        return text
    }

    private func hero(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            Image.telescanLogo
                .resizable()
                .scaledToFit()
                .frame(width: 82 * scale, height: 82 * scale)
                .accessibilityHidden(true)

            Text(Inc.Onboarding.welcomeTitle.localized)
                .font(.system(size: 36 * scale, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.68)
                .padding(.top, 15 * scale)

            Text(Inc.Onboarding.shortOnboardingMsg.localized)
                .font(.system(size: 17 * scale, weight: .regular))
                .multilineTextAlignment(.center)
                .lineSpacing(4 * scale)
                .padding(.top, 8 * scale)
        }
        .foregroundStyle(.primary)
        .frame(maxWidth: 330 * scale)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func bottomContent(
        width: CGFloat,
        scale: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            Text(legalText(scale: scale))
                .multilineTextAlignment(.center)
                .tint(accentColor)
                .frame(maxWidth: 340 * scale)

            ZStack {
                StartButton(
                    title: Inc.Onboarding.start.localized,
                    accentColor: accentColor
                ) {
                    showHowItWorks = true
                }
            }
            .frame(height: 50)
            .frame(maxWidth: min(360 * scale, max(0, width - 30)))
            .padding(.top, 27 * scale)
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let currentScale = scale(for: geometry.size.width)

                ZStack {
                    backgroundColor
                        .ignoresSafeArea()

                    backgroundCircle(
                        size: geometry.size,
                        scale: currentScale
                    )

                    hero(scale: currentScale)
                        .position(
                            x: geometry.size.width / 2,
                            y: geometry.size.height * 0.51
                        )

                    VStack {
                        Spacer()
                        bottomContent(
                            width: geometry.size.width,
                            scale: currentScale
                        )
                    }
                    .padding(.horizontal, 15)
                    .padding(.bottom, 16 * currentScale)
                }
            }
            .tint(accentColor)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showHowItWorks) {
                HowTelescanWorksView()
            }
        }
    }
}
