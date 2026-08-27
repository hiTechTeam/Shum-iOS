import SwiftUI

struct AppCoordinatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var coordinator: AppCoordinator

    var body: some View {
        ZStack {
            Group {
                if coordinator.isRegistered {
                    MainContentView()
                } else if coordinator.isAuthenticated {
                    AuthenticatedOnboardingView()
                } else {
                    Welcome()
                        .id(coordinator.authenticationFlowID)
                }
            }

            if coordinator.showSplash {
                AppSplashView()
                    .zIndex(1)
            }
        }
        .environmentObject(coordinator)
        .task {
            guard coordinator.showSplash else { return }

            try? await Task.sleep(
                nanoseconds: 2_000_000_000
            )

            guard !Task.isCancelled else { return }
            coordinator.showSplash = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                coordinator.prepareForBackground()
            }
            coordinator.updateApplicationState(isActive: phase == .active)
            if phase == .active {
                Task {
                    await coordinator.refreshSession()
                }
            }
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
                .ignoresSafeArea()

            Image.telescanLogo
                .resizable()
                .scaledToFit()
                .frame(width: 82, height: 82)
        }
        .accessibilityHidden(true)
    }
}
