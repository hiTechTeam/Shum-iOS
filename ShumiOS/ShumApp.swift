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
            .modifier(ShumApplicationTheme(appearance: appearance))
            .environmentObject(appearance)
        }
    }
}

private struct ShumApplicationTheme: ViewModifier {
    @ObservedObject var appearance: ShumAppearanceStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .shumTheme(
                appearance.resolvedTheme(for: colorScheme).palette,
                followsSystem: appearance.followsSystem
            )
            .onAppear { appearance.updateSystemColorScheme(colorScheme) }
            .onChange(of: colorScheme) { scheme in
                appearance.updateSystemColorScheme(scheme)
            }
            .onChange(of: appearance.followsSystem) { followsSystem in
                if followsSystem { appearance.updateSystemColorScheme(colorScheme) }
            }
    }
}
