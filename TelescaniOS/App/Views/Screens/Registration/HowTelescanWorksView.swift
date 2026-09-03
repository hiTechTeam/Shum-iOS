import SwiftUI

struct HowTelescanWorksView: View {

    @State private var showIdentityVerification = false

    private let referenceWidth: CGFloat = 390
    private let accentColor = Color(
        red: 10 / 255,
        green: 132 / 255,
        blue: 255 / 255
    )

    private var backgroundColor: Color {
        Color("ls-Background")
    }

    private func scale(for width: CGFloat) -> CGFloat {
        min(max(width / referenceWidth, 0.84), 1.12)
    }

    private func feature(
        icon: String,
        title: String,
        description: String,
        scale: CGFloat
    ) -> some View {
        HStack(alignment: .top, spacing: 15 * scale) {
            Image(systemName: icon)
                .font(.system(size: 20 * scale, weight: .medium))
                .foregroundStyle(accentColor)
                .frame(width: 42 * scale, height: 42 * scale)
                .background(accentColor.opacity(0.12))
                .clipShape(Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4 * scale) {
                Text(title)
                    .font(.system(size: 17 * scale, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.system(size: 15 * scale, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2 * scale)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func explanation(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(Inc.Onboarding.howItWorksTitle.localized)
                .font(.system(size: 30 * scale, weight: .heavy))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 23 * scale) {
                feature(
                    icon: "dot.radiowaves.left.and.right",
                    title: Inc.Onboarding.nearbyFeatureTitle.localized,
                    description: Inc.Onboarding.nearbyFeatureDescription.localized,
                    scale: scale
                )

                feature(
                    icon: "person.crop.circle",
                    title: Inc.Onboarding.profileFeatureTitle.localized,
                    description: Inc.Onboarding.profileFeatureDescription.localized,
                    scale: scale
                )

                feature(
                    icon: "paperplane",
                    title: Inc.Onboarding.telegramFeatureTitle.localized,
                    description: Inc.Onboarding.telegramFeatureDescription.localized,
                    scale: scale
                )
            }
            .padding(.top, 34 * scale)
        }
        .frame(maxWidth: 340 * scale)
    }

    var body: some View {
        GeometryReader { geometry in
            let currentScale = scale(for: geometry.size.width)

            ZStack {
                backgroundColor
                    .ignoresSafeArea()

                ScrollView {
                    explanation(scale: currentScale)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 15)
                        .padding(.top, 56 * currentScale)
                        .padding(.bottom, 96 * currentScale)
                }
                .scrollIndicators(.hidden)

                VStack {
                    Spacer()

                    RegistrationPrimaryButton(
                        title: Inc.Onboarding.goNext.localized,
                        accentColor: accentColor
                    ) {
                        showIdentityVerification = true
                    }
                    .frame(height: 50)
                    .frame(
                        maxWidth: min(
                            360 * currentScale,
                            max(0, geometry.size.width - 30)
                        )
                    )
                }
                .padding(.horizontal, 15)
                .padding(.bottom, 16 * currentScale)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showIdentityVerification) {
            AppleIdentityVerificationView()
        }
    }
}
