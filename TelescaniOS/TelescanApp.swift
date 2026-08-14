import SwiftUI

@main
struct Telescan: App {
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup { coordinator.start() }
    }
}
