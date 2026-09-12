import SwiftUI

@main
struct Shum: App {
    @StateObject private var coordinator = AppCoordinator()

    init() {
        let back = ShumPixelSymbols.image(named: "chevron.left")
        UINavigationBar.appearance().backIndicatorImage = back
        UINavigationBar.appearance().backIndicatorTransitionMaskImage = back
    }

    var body: some Scene {
        WindowGroup { coordinator.start().preferredColorScheme(.dark).tint(.accentColor) }
    }
}
