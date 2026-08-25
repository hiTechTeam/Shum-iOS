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
    @EnvironmentObject private var coordinator: AppCoordinator

    var body: some View {
        NavigationStack {
            switch coordinator.onboardingStage {
            case .telegram:
                AuthCode()
                    .navigationBarBackButtonHidden(true)
            case .scanning:
                ScanToggleView()
                    .navigationBarBackButtonHidden(true)
            }
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
