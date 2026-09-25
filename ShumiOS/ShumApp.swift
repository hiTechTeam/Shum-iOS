import SwiftUI

@main
struct Shum: App {
    @UIApplicationDelegateAdaptor(ShumApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var appearance = ShumAppearanceStore.shared
    @StateObject private var language = ShumLanguageStore.shared

    var body: some Scene {
        WindowGroup {
            coordinator.start()
            .modifier(ShumApplicationTheme(appearance: appearance))
            .modifier(ShumApplicationLanguage(language: language))
            .environmentObject(appearance)
            .environmentObject(language)
        }
    }
}

private struct ShumApplicationLanguage: ViewModifier {
    @ObservedObject var language: ShumLanguageStore

    func body(content: Content) -> some View {
        content
            .environment(\.locale, language.locale)
            .environment(\.layoutDirection, language.layoutDirection)
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
