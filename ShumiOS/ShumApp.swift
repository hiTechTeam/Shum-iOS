import SwiftUI

@main
struct Shum: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ShumCaptureProtectedContainer {
                coordinator.start()
                    .preferredColorScheme(.dark)
                    .tint(.accentColor)
            }
        }
    }
}
