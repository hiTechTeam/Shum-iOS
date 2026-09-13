import SwiftUI

struct AppCoordinatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var coordinator: AppCoordinator
    @StateObject private var appLock = ShumAppLock.shared

    @State private var hasReachedMinimumSplashDuration = false

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
        }
        .onOpenURL { url in
            do { coordinator.invitation = try SpotchatContactCard.parse(url) }
            catch { coordinator.invitationError = error.localizedDescription }
        }
        .alert("Контакт Shum", isPresented: Binding(get: { coordinator.invitationError != nil }, set: { if !$0 { coordinator.invitationError = nil } })) {
            Button("Понятно") { coordinator.invitationError = nil }
        } message: { Text(coordinator.invitationError ?? "") }
        .environmentObject(coordinator)
        .task {
            coordinator.updateApplicationState(
                isActive: scenePhase == .active
            )

            if coordinator.isRegistered, scenePhase == .active {
                _ = await appLock.unlock()
            }

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
        .shumOnChange(of: scenePhase) { _, phase in
            coordinator.updateApplicationState(isActive: phase == .active)
            if phase == .active {
                Task {
                    if coordinator.isRegistered {
                        _ = await appLock.unlock()
                    }
                    await coordinator.refreshSession()
                }
            } else if phase == .background {
                appLock.lock()
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
}

private struct ShumLockedView: View {
    @ObservedObject var appLock: ShumAppLock

    var body: some View {
        ZStack {
            Color("ls-Background").ignoresSafeArea()

            VStack(spacing: 18) {
                Image.shumLogo
                    .resizable()
                    .scaledToFit()
                    .frame(width: 76, height: 76)

                Text("Shum заблокирован")
                    .font(.title2.weight(.semibold))

                Text("Подтвердите владельца устройства, чтобы открыть переписку.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)

                Button {
                    Task { _ = await appLock.unlock() }
                } label: {
                    Text("Открыть с \(appLock.biometricTitle)")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.black)
                        .frame(maxWidth: 300)
                        .frame(height: 50)
                        .background(Color.accentColor, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(appLock.isAuthenticating)

                if let message = appLock.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }
            }
            .padding(24)
        }
    }
}

private struct AppSplashView: View {
    var body: some View {
        ZStack {
            Color("ls-Background")

            Image.shumLogo
                .resizable()
                .scaledToFit()
                .frame(width: 82, height: 82)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
