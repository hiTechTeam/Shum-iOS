import AuthenticationServices
import SwiftUI

struct Welcome: View {

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var currentNonce: String?
    @State private var isSigningIn = false
    @State private var signInFailed = false

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

        text.foregroundColor = Color.primary
        text.font = .system(size: 14 * scale, weight: .regular)

        if let privacyRange = text.range(of: privacyTitle) {
            text[privacyRange].link = privacyPolicyURL
            text[privacyRange].foregroundColor = accentColor
            text[privacyRange].underlineStyle = .single
            text[privacyRange].font = .system(
                size: 14 * scale,
                weight: .bold
            )
        }

        if let termsRange = text.range(of: termsTitle) {
            text[termsRange].link = termsOfServiceURL
            text[termsRange].foregroundColor = accentColor
            text[termsRange].underlineStyle = .single
            text[termsRange].font = .system(
                size: 14 * scale,
                weight: .bold
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

            Text(Inc.Common.Telescan)
                .font(.system(size: 36 * scale, weight: .heavy))
                .padding(.top, 1 * scale)

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
                #if TELESCAN_PERSONAL_TEAM
                Button {
                    coordinator.startTemporaryTelegramSignIn()
                } label: {
                    Text(Inc.Onboarding.start.localized)
                        .font(.system(size: 17 * scale, weight: .semibold))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(
                            colorScheme == .dark ? Color.black : Color.white
                        )
                }
                .buttonStyle(.plain)
                .background(
                    Capsule().fill(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                )
                #else
                SignInWithAppleButton(.continue) { request in
                    do {
                        let nonce = try AppleSignInNonce.make()
                        currentNonce = nonce
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = AppleSignInNonce.hashed(nonce)
                    } catch {
                        currentNonce = nil
                        signInFailed = true
                    }
                } onCompletion: { result in
                    completeAppleAuthorization(result)
                }
                .signInWithAppleButtonStyle(
                    colorScheme == .dark ? .white : .black
                )
                .clipShape(Capsule())
                .allowsHitTesting(!isSigningIn)

                if isSigningIn {
                    Capsule()
                        .fill(Color.black.opacity(0.32))
                    ProgressView()
                        .tint(.white)
                }
                #endif
            }
            .frame(height: 50)
            .frame(maxWidth: min(360 * scale, width - 30))
            .padding(.top, 27 * scale)
        }
    }

    private func completeAppleAuthorization(
        _ result: Result<ASAuthorization, Error>
    ) {
        guard case .success(let authorization) = result,
              let credential = authorization.credential
                as? ASAuthorizationAppleIDCredential,
              let nonce = currentNonce,
              let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            if case .failure(let error) = result,
               (error as? ASAuthorizationError)?.code == .canceled {
                return
            }
            signInFailed = true
            return
        }
        let name = credential.fullName.flatMap {
            let value = PersonNameComponentsFormatter().string(from: $0)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        Task { @MainActor in
            isSigningIn = true
            defer { isSigningIn = false }
            do {
                let response = try await FetchService.fetch.signInWithApple(
                    identityToken: identityToken,
                    nonce: nonce,
                    name: name
                )
                coordinator.completedAppleSignIn(profile: response.profile)
            } catch {
                signInFailed = true
            }
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
        }
        .alert(
            Inc.Onboarding.appleSignInFailed.localized,
            isPresented: $signInFailed
        ) {
            Button(Inc.Common.okey.localized, role: .cancel) {}
        }
    }
}
