import SwiftUI

struct AppCoordinatorView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject var coordinator: AppCoordinator
    
    var body: some View {
        Group {
            if coordinator.isRegistered {
                MainContentView()
            } else {
                Welcome()
            }
        }
        .environmentObject(coordinator)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    await coordinator.refreshSession()
                }
            }
        }
    }
}
