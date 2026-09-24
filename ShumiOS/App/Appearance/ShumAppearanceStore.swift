import SwiftUI
import UIKit

/// The single semantic color source for the whole app. Components use the
/// root tint for ordinary accents and this palette for derived surfaces such
/// as outgoing message bubbles.
struct ShumThemePalette {
    let accentUIColor: UIColor
    let canvasUIColor: UIColor
    let chatDoodleUIColor: UIColor
    let chatDoodleOpacity: Double
    let colorScheme: ColorScheme
    var usesMonochromeChrome = false

    var accent: Color { Color(uiColor: accentUIColor) }
    var canvas: Color { Color(uiColor: canvasUIColor) }
    var chatDoodle: Color { Color(uiColor: chatDoodleUIColor) }
    var accentForeground: Color { Color(uiColor: accentForegroundUIColor) }
    var privacySurface: Color { colorScheme == .dark ? .black : .white }
    var tabBarIconUIColor: UIColor? {
        guard usesMonochromeChrome else { return nil }
        return colorScheme == .dark ? .white : .black
    }
    var pinnedRowSurface: Color {
        // Pinning uses the same quiet neutral surface in every theme.
        colorScheme == .dark
            ? Color(white: 245 / 255).opacity(0.06)
            : Color(red: 22 / 255, green: 23 / 255, blue: 22 / 255).opacity(0.05)
    }

    var accentForegroundUIColor: UIColor {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        return accentUIColor.contrastingForeground(
            resolvedFor: UITraitCollection(userInterfaceStyle: style)
        )
    }

    func outgoingMessageBubble(for colorScheme: ColorScheme) -> Color {
        Color(
            uiColor: accentUIColor.mixed(
                with: colorScheme == .dark ? .black : .white,
                accentAmount: colorScheme == .dark ? 0.30 : 0.17
            )
        )
    }

    func outgoingMessageMetadata(for colorScheme: ColorScheme) -> Color {
        Color(
            uiColor: accentUIColor.mixed(
                with: colorScheme == .dark ? .white : .black,
                accentAmount: colorScheme == .dark ? 0.68 : 0.48
            )
        )
    }
}

private extension UIColor {
    func contrastingForeground(resolvedFor traits: UITraitCollection) -> UIColor {
        let resolved = resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return traits.userInterfaceStyle == .dark ? .black : .white
        }

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }

        let luminance = 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast ? .black : .white
    }

    func mixed(with base: UIColor, accentAmount: CGFloat) -> UIColor {
        var accentRed: CGFloat = 0
        var accentGreen: CGFloat = 0
        var accentBlue: CGFloat = 0
        var accentAlpha: CGFloat = 0
        var baseRed: CGFloat = 0
        var baseGreen: CGFloat = 0
        var baseBlue: CGFloat = 0
        var baseAlpha: CGFloat = 0

        guard getRed(&accentRed, green: &accentGreen, blue: &accentBlue, alpha: &accentAlpha),
              base.getRed(&baseRed, green: &baseGreen, blue: &baseBlue, alpha: &baseAlpha) else {
            return self
        }

        let amount = min(max(accentAmount, 0), 1)
        return UIColor(
            red: baseRed + (accentRed - baseRed) * amount,
            green: baseGreen + (accentGreen - baseGreen) * amount,
            blue: baseBlue + (accentBlue - baseBlue) * amount,
            alpha: baseAlpha + (accentAlpha - baseAlpha) * amount
        )
    }
}

private struct ShumThemePaletteKey: EnvironmentKey {
    static let defaultValue = ShumThemePalette(
        accentUIColor: .systemGreen,
        canvasUIColor: UIColor(red: 8 / 255, green: 10 / 255, blue: 9 / 255, alpha: 1),
        chatDoodleUIColor: UIColor(red: 120 / 255, green: 144 / 255, blue: 131 / 255, alpha: 1),
        chatDoodleOpacity: 0.28,
        colorScheme: .dark
    )
}

extension EnvironmentValues {
    var shumThemePalette: ShumThemePalette {
        get { self[ShumThemePaletteKey.self] }
        set { self[ShumThemePaletteKey.self] = newValue }
    }
}

extension View {
    func shumGroupedScreenBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(ShumThemeCanvas().ignoresSafeArea())
            .toolbarBackground(.hidden, for: .navigationBar)
    }

    /// Applies the theme once at the application root. SwiftUI descendants,
    /// presented system views and embedded UIKit controls inherit the same
    /// accent instead of keeping separate green constants.
    func shumTheme(_ palette: ShumThemePalette, followsSystem: Bool = false) -> some View {
        tint(palette.accent)
            .accentColor(palette.accent)
            .preferredColorScheme(followsSystem ? nil : palette.colorScheme)
            .environment(\.shumThemePalette, palette)
            .background {
                palette.canvas
                    .ignoresSafeArea()
            }
            .background {
                ShumWindowTintBridge(
                    tintColor: palette.accentUIColor,
                    canvasColor: palette.canvasUIColor,
                    tabBarIconColor: palette.tabBarIconUIColor
                )
                    .frame(width: 0, height: 0)
            }
    }
}

struct ShumThemeCanvas: View {
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        palette.canvas
    }
}

struct ShumChatCanvas: View {
    @Environment(\.shumThemePalette) private var palette

    var body: some View {
        ZStack {
            palette.canvas
            Image("ChatDoodleWallpaper")
                .renderingMode(.template)
                .resizable(resizingMode: .tile)
                .foregroundStyle(palette.chatDoodle)
                .opacity(palette.chatDoodleOpacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ShumWindowTintBridge: UIViewRepresentable {
    let tintColor: UIColor
    let canvasColor: UIColor
    let tabBarIconColor: UIColor?

    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            view.window?.tintColor = tintColor
            view.window?.backgroundColor = canvasColor
            view.window?.rootViewController?.view.backgroundColor = canvasColor
            guard let rootView = view.window?.rootViewController?.view else { return }
            Self.updateTabBars(
                in: rootView,
                selectedColor: tabBarIconColor ?? tintColor,
                unselectedColor: Self.unselectedTabBarColor(
                    monochromeColor: tabBarIconColor
                )
            )
        }
    }

    private static func unselectedTabBarColor(
        monochromeColor: UIColor?
    ) -> UIColor? {
        guard let monochromeColor else { return nil }
        if #available(iOS 26.0, *) {
            return monochromeColor
        }
        return .systemGray
    }

    private static func updateTabBars(
        in view: UIView,
        selectedColor: UIColor,
        unselectedColor: UIColor?
    ) {
        if let tabBar = view as? UITabBar {
            tabBar.tintColor = selectedColor
            tabBar.unselectedItemTintColor = unselectedColor
        }
        view.subviews.forEach {
            updateTabBars(
                in: $0,
                selectedColor: selectedColor,
                unselectedColor: unselectedColor
            )
        }
    }
}

@MainActor
final class ShumAppearanceStore: ObservableObject {
    enum Theme: String, CaseIterable, Identifiable {
        case classic
        case darkPink
        case lightClassic
        case lightPink
        case monochromeLight
        case monochromeDark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .classic: "Dark Classic"
            case .darkPink: "Dark Pink"
            case .lightClassic: "Light Classic"
            case .lightPink: "Light Pink"
            case .monochromeLight: "Monochrome Light"
            case .monochromeDark: "Monochrome Dark"
            }
        }

        var colorScheme: ColorScheme {
            switch self {
            case .classic, .darkPink, .monochromeDark: .dark
            case .lightClassic, .lightPink, .monochromeLight: .light
            }
        }

        var accentColor: Color {
            palette.accent
        }

        var accentUIColor: UIColor {
            palette.accentUIColor
        }

        var palette: ShumThemePalette {
            switch self {
            case .classic:
                ShumThemePalette(
                    accentUIColor: .systemGreen,
                    canvasUIColor: UIColor(
                        red: 8 / 255,
                        green: 10 / 255,
                        blue: 9 / 255,
                        alpha: 1
                    ),
                    chatDoodleUIColor: UIColor(
                        red: 120 / 255,
                        green: 144 / 255,
                        blue: 131 / 255,
                        alpha: 1
                    ),
                    chatDoodleOpacity: 0.28,
                    colorScheme: colorScheme
                )
            case .darkPink:
                ShumThemePalette(
                    accentUIColor: UIColor(
                        red: 1,
                        green: 79 / 255,
                        blue: 154 / 255,
                        alpha: 1
                    ),
                    canvasUIColor: UIColor(
                        red: 8 / 255,
                        green: 10 / 255,
                        blue: 9 / 255,
                        alpha: 1
                    ),
                    chatDoodleUIColor: UIColor(
                        red: 185 / 255,
                        green: 129 / 255,
                        blue: 156 / 255,
                        alpha: 1
                    ),
                    chatDoodleOpacity: 0.26,
                    colorScheme: colorScheme
                )
            case .lightClassic:
                ShumThemePalette(
                    accentUIColor: .systemGreen,
                    canvasUIColor: UIColor(
                        red: 250 / 255,
                        green: 250 / 255,
                        blue: 250 / 255,
                        alpha: 1
                    ),
                    chatDoodleUIColor: UIColor(
                        red: 82 / 255,
                        green: 106 / 255,
                        blue: 92 / 255,
                        alpha: 1
                    ),
                    chatDoodleOpacity: 0.20,
                    colorScheme: colorScheme
                )
            case .lightPink:
                ShumThemePalette(
                    accentUIColor: UIColor(
                        red: 1,
                        green: 79 / 255,
                        blue: 154 / 255,
                        alpha: 1
                    ),
                    canvasUIColor: UIColor(
                        red: 1,
                        green: 247 / 255,
                        blue: 251 / 255,
                        alpha: 1
                    ),
                    chatDoodleUIColor: UIColor(
                        red: 157 / 255,
                        green: 100 / 255,
                        blue: 127 / 255,
                        alpha: 1
                    ),
                    chatDoodleOpacity: 0.19,
                    colorScheme: colorScheme
                )
            case .monochromeLight:
                ShumThemePalette(
                    accentUIColor: UIColor(
                        red: 22 / 255,
                        green: 23 / 255,
                        blue: 22 / 255,
                        alpha: 1
                    ),
                    canvasUIColor: UIColor(
                        red: 250 / 255,
                        green: 250 / 255,
                        blue: 250 / 255,
                        alpha: 1
                    ),
                    chatDoodleUIColor: UIColor(
                        red: 28 / 255,
                        green: 29 / 255,
                        blue: 28 / 255,
                        alpha: 1
                    ),
                    chatDoodleOpacity: 0.14,
                    colorScheme: colorScheme,
                    usesMonochromeChrome: true
                )
            case .monochromeDark:
                ShumThemePalette(
                    accentUIColor: UIColor(
                        red: 245 / 255,
                        green: 245 / 255,
                        blue: 245 / 255,
                        alpha: 1
                    ),
                    canvasUIColor: UIColor(
                        red: 8 / 255,
                        green: 10 / 255,
                        blue: 9 / 255,
                        alpha: 1
                    ),
                    chatDoodleUIColor: UIColor(
                        red: 213 / 255,
                        green: 215 / 255,
                        blue: 214 / 255,
                        alpha: 1
                    ),
                    chatDoodleOpacity: 0.15,
                    colorScheme: colorScheme,
                    usesMonochromeChrome: true
                )
            }
        }
    }

    static let shared = ShumAppearanceStore()

    @Published private(set) var followsSystem: Bool
    @Published private var selectedTheme: Theme
    @Published private var systemColorScheme: ColorScheme

    private let defaultsKey = "shum.appearance.theme"
    private let systemDefaultsKey = "shum.appearance.followsSystem"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        followsSystem = defaults.object(forKey: systemDefaultsKey) == nil
            ? true : defaults.bool(forKey: systemDefaultsKey)
        systemColorScheme = UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        selectedTheme = defaults.string(forKey: defaultsKey)
            .flatMap(Theme.init(rawValue:))
            ?? .classic
    }

    var theme: Theme { resolvedTheme(for: systemColorScheme) }
    var accentColor: Color { theme.accentColor }
    var accentUIColor: UIColor { theme.accentUIColor }
    var palette: ShumThemePalette { theme.palette }

    func resolvedTheme(for systemScheme: ColorScheme) -> Theme {
        followsSystem ? (systemScheme == .dark ? .classic : .lightClassic) : selectedTheme
    }

    func updateSystemColorScheme(_ scheme: ColorScheme) {
        guard followsSystem, systemColorScheme != scheme else { return }
        systemColorScheme = scheme
    }

    func setFollowsSystem(_ enabled: Bool) {
        guard followsSystem != enabled else { return }
        if !enabled {
            selectedTheme = theme
            defaults.set(selectedTheme.rawValue, forKey: defaultsKey)
        }
        followsSystem = enabled
        defaults.set(enabled, forKey: systemDefaultsKey)
    }

    func select(_ theme: Theme) {
        guard followsSystem || selectedTheme != theme else { return }
        selectedTheme = theme
        followsSystem = false
        defaults.set(false, forKey: systemDefaultsKey)
        defaults.set(theme.rawValue, forKey: defaultsKey)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func resetToClassic() {
        selectedTheme = .classic
        followsSystem = true
        defaults.removeObject(forKey: defaultsKey)
        defaults.removeObject(forKey: systemDefaultsKey)
    }
}
