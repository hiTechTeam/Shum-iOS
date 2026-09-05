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
                if coordinator.isRegistered {
                    MainContentView(
                        profilePhotoViewModel: coordinator.profilePhotoViewModel
                    )
                } else if coordinator.isAuthenticated {
                    AuthenticatedOnboardingView()
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
        .onChange(of: coordinator.hasCompletedInitialSessionRefresh) {
            _, isComplete in
            guard isComplete else { return }
            hideSplashIfReady()
        }
        .onChange(of: scenePhase) { _, phase in
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

private struct AuthenticatedOnboardingView: View {
    var body: some View {
        NavigationStack {
            AuthCode()
                .navigationBarBackButtonHidden(true)
        }
    }
}

private struct AppSplashView: View {
    var body: some View {
        ZStack {
            Color("ls-Background")

            Image.telescanLogo
                .resizable()
                .scaledToFit()
                .frame(width: 82, height: 82)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
