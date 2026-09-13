import SwiftUI

@main
struct Shum: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            ShumSecureCaptureContainer {
                coordinator.start()
                    .preferredColorScheme(.dark)
                    .tint(.accentColor)
            }
        }
    }
}
