import SwiftUI

struct AppCoordinatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var coordinator: AppCoordinator

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
