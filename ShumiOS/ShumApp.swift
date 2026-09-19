import SwiftUI

@main
struct Shum: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var appearance = ShumAppearanceStore.shared

    var body: some Scene {
        WindowGroup {
            ShumCaptureProtectedContainer {
                coordinator.start()
            }
            .shumTheme(appearance.palette)
            .environmentObject(appearance)
        }
    }
}
