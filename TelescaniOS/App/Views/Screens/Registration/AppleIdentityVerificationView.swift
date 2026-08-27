import AuthenticationServices
import SwiftUI

struct AppleIdentityVerificationView: View {

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var currentNonce: String?
    @State private var isSigningIn = false
    @State private var signInFailed = false
    @State private var showTelegramCode = false

    private let referenceWidth: CGFloat = 390

    private var backgroundColor: Color {
        Color("ls-Background")
    }

    private func scale(for width: CGFloat) -> CGFloat {
        min(max(width / referenceWidth, 0.84), 1.12)
    }

    private func explanation(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(Inc.Onboarding.appleIdentityTitle.localized)
                .font(.system(size: 30 * scale, weight: .heavy))
                .multilineTextAlignment(.center)

            Text(Inc.Onboarding.appleIdentityDescription.localized)
                .telescanDescriptionStyle()
                .multilineTextAlignment(.center)
                .padding(.top, 12 * scale)
        }
        .frame(maxWidth: 340 * scale)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func appleSignInButton() -> some View {
        #if TELESCAN_PERSONAL_TEAM
        Button {
            showTelegramCode = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 20, weight: .medium))

                Text(Inc.Onboarding.appleSignInButton.localized)
                    .font(.system(size: 17, weight: .medium))
            }
            .foregroundStyle(colorScheme == .dark ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(colorScheme == .dark ? Color.white : Color.black)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Inc.Onboarding.appleSignInHint.localized)
        #else
        ZStack {
            SignInWithAppleButton(.signIn) { request in
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
        }
        #endif
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
        GeometryReader { geometry in
            let currentScale = scale(for: geometry.size.width)

            ZStack {
                backgroundColor
                    .ignoresSafeArea()

                explanation(scale: currentScale)
                    .position(
                        x: geometry.size.width / 2,
                        y: geometry.size.height * 0.47
                    )

                VStack {
                    Spacer()
                    appleSignInButton()
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
        .navigationDestination(isPresented: $showTelegramCode) {
            AuthCode()
                .navigationBarBackButtonHidden(true)
        }
        .alert(
            Inc.Onboarding.appleSignInFailed.localized,
            isPresented: $signInFailed
        ) {
            Button(Inc.Common.okey.localized, role: .cancel) {}
        }
    }
}
