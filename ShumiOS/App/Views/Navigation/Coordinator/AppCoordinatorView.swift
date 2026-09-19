import SwiftUI

struct AppCoordinatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var coordinator: AppCoordinator
    @StateObject private var appLock = ShumAppLock.shared

    @State private var hasReachedMinimumSplashDuration = false
    @State private var showsAppSwitcherPrivacyCover = false

    private let minimumSplashDuration: UInt64 = 600_000_000
    private let remainingFallbackDuration: UInt64 = 1_400_000_000

    var body: some View {
        ZStack {
            Group {
                if coordinator.deletingProfile {
                    VStack(spacing: 20) {
                        Text("Завершение удаления").font(.title2.bold())
                        Text(coordinator.deletionError ?? "Обмен сообщениями остановлен.").multilineTextAlignment(.center)
                        RegistrationPrimaryButton(title: "Повторить удаление") { coordinator.finishDeletion() }
                    }.padding(24)
                } else if coordinator.isRegistered, let chat = coordinator.chat {
                    MainContentView(chat: chat,
                        profilePhotoViewModel: coordinator.profilePhotoViewModel
                    )
                } else {
                    Welcome()
                        .id(coordinator.authenticationFlowID)
                }
            }

            if coordinator.showSplash {
                AppSplashView()
                    .transition(.opacity)
                    .zIndex(1)
            }

            if coordinator.isRegistered && appLock.isLocked {
                ShumLockedView(appLock: appLock)
                    .transition(.opacity)
                    .zIndex(2)
            }

            ShumCapturePrivacyOverlay()
                .zIndex(10)

            if showsAppSwitcherPrivacyCover {
                ShumPrivacyCover()
                    .zIndex(11)
            }
        }
        .onOpenURL { url in
            coordinator.handleInvitationURL(url)
        }
        .alert("Контакт Shum", isPresented: Binding(get: { coordinator.invitationError != nil }, set: { if !$0 { coordinator.invitationError = nil } })) {
            Button("Понятно") { coordinator.invitationError = nil }
        } message: { Text(coordinator.invitationError ?? "") }
        .environmentObject(coordinator)
        .task {
            coordinator.updateApplicationState(
                isActive: scenePhase == .active
            )

            guard coordinator.showSplash else { return }

            try? await Task.sleep(
                nanoseconds: minimumSplashDuration
            )

            guard !Task.isCancelled else { return }
            hasReachedMinimumSplashDuration = true
            hideSplashIfReady()

            guard coordinator.showSplash else { return }

            try? await Task.sleep(
                nanoseconds: remainingFallbackDuration
            )

            guard !Task.isCancelled, coordinator.showSplash else { return }
            hideSplash()
        }
        .shumOnChange(of: coordinator.hasCompletedInitialSessionRefresh) {
            _, isComplete in
            guard isComplete else { return }
            hideSplashIfReady()
        }
        .shumOnChange(of: appLock.isLocked) { _, _ in
            coordinator.updateApplicationState(
                isActive: scenePhase == .active
            )
        }
        .shumOnChange(of: scenePhase) { previousPhase, phase in
            coordinator.updateApplicationState(isActive: phase == .active)

            updateAppSwitcherPrivacyCover(
                from: previousPhase,
                to: phase
            )

            if phase == .active {
                Task {
                    await coordinator.refreshSession()
                }
            }
        }
    }

    private func hideSplashIfReady() {
        guard hasReachedMinimumSplashDuration,
              coordinator.hasCompletedInitialSessionRefresh else {
            return
        }

        hideSplash()
    }

    private func hideSplash() {
        guard coordinator.showSplash else { return }

        withAnimation(.easeOut(duration: 0.18)) {
            coordinator.showSplash = false
        }
    }

    private func updateAppSwitcherPrivacyCover(
        from previousPhase: ScenePhase,
        to phase: ScenePhase
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            switch phase {
            case .background:
                showsAppSwitcherPrivacyCover = true
            case .inactive:
                // Cover the outgoing app before iOS takes its app-switcher
                // snapshot. On the return path, remove the cover while the
                // scene is still inactive so it cannot flash on screen.
                showsAppSwitcherPrivacyCover = previousPhase == .active
            case .active:
                showsAppSwitcherPrivacyCover = false
            @unknown default:
                showsAppSwitcherPrivacyCover = true
            }
        }
    }
}

private struct ShumLockedView: View {
    @Environment(\.shumThemePalette) private var palette
    @ObservedObject var appLock: ShumAppLock
    @State private var showingPasscode: Bool
    @State private var isWaitingForAutomaticBiometrics: Bool
    @State private var code = ""
    @State private var isCheckingCode = false

    init(appLock: ShumAppLock) {
        self.appLock = appLock
        let usesAutomaticBiometrics = appLock.preferredMethod == .biometrics
            && appLock.isBiometricsEnabled
        _showingPasscode = State(
            initialValue: appLock.preferredMethod == .passcode
        )
        _isWaitingForAutomaticBiometrics = State(
            initialValue: usesAutomaticBiometrics
        )
    }

    var body: some View {
        ZStack {
            ShumThemeCanvas().ignoresSafeArea()

            if isWaitingForAutomaticBiometrics {
                AppSplashView()
            } else if showingPasscode, appLock.hasPasscode {
                passcodeContent
            } else {
                biometricContent
            }
        }
        .task {
            guard appLock.preferredMethod == .biometrics,
                  appLock.isBiometricsEnabled,
                  !showingPasscode else {
                return
            }

            let unlocked = await appLock.unlock()
            guard !unlocked else { return }

            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isWaitingForAutomaticBiometrics = false
            }
        }
    }

    private var passcodeContent: some View {
        VStack(spacing: 18) {
            ShumLogoMark()
                .frame(width: 70, height: 70)

            Text("Введите код Shum")
                .font(.title2.weight(.semibold))

            Text("Введите пять цифр, чтобы открыть переписку.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ShumPasscodeInput(code: $code)
                .padding(.vertical, 12)

            if let message = appLock.errorMessage {
                errorText(message)
            }

            if appLock.isBiometricsEnabled {
                Button("Открыть с \(appLock.biometricTitle)") {
                    code = ""
                    showingPasscode = false
                    Task { _ = await appLock.unlockWithBiometrics() }
                }
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.accentColor)
                .frame(height: 44)
            }
        }
        .padding(24)
        .onChange(of: code) { value in
            guard value.count == 5, !isCheckingCode else { return }
            isCheckingCode = true
            Task {
                let unlocked = await appLock.verifyPasscode(value)
                isCheckingCode = false
                if !unlocked { code = "" }
            }
        }
    }

    private var biometricContent: some View {
        VStack(spacing: 18) {
            ShumLogoMark()
                .frame(width: 76, height: 76)

            Text("Shum заблокирован")
                .font(.title2.weight(.semibold))

            Text("Подтвердите владельца устройства, чтобы открыть переписку.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if appLock.isBiometricsEnabled {
                Button {
                    Task { _ = await appLock.unlockWithBiometrics() }
                } label: {
                    Text("Открыть с \(appLock.biometricTitle)")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(palette.accentForeground)
                        .frame(maxWidth: 300)
                        .frame(height: 50)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(appLock.isAuthenticating)
            }

            if appLock.hasPasscode {
                Button("Ввести код") {
                    appLock.errorMessage = nil
                    showingPasscode = true
                }
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(height: 44)
            }

            if let message = appLock.errorMessage {
                errorText(message)
            }
        }
        .padding(24)
    }

    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
    }
}

private struct AppSplashView: View {
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        ZStack {
            palette.privacySurface

            ShumLogoMark(color: palette.accent)
                .frame(width: 82, height: 82)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
