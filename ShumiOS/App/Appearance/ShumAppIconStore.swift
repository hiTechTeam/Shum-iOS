import SwiftUI
import UIKit

@MainActor
final class ShumAppIconStore: ObservableObject {
    enum Icon: String, CaseIterable, Identifiable {
        case classicGreen
        case darkPink
        case lightClassic
        case lightPink
        case monochromeLight
        case monochromeDark

        var id: String { rawValue }

        var title: String {
            switch self {
            case .classicGreen: "Classic Green"
            case .darkPink: "Dark Pink"
            case .lightClassic: "Light Classic"
            case .lightPink: "Light Pink"
            case .monochromeLight: "Mono Light"
            case .monochromeDark: "Mono Dark"
            }
        }

        var alternateName: String? {
            switch self {
            case .classicGreen: nil
            case .darkPink: "AppIconPink"
            case .lightClassic: "AppIconLight"
            case .lightPink: "AppIconLightPink"
            case .monochromeLight: "AppIconMonoLight"
            case .monochromeDark: "AppIconMono"
            }
        }

        var backgroundColor: Color {
            switch self {
            case .lightClassic, .monochromeLight:
                Color(uiColor: UIColor(red: 250 / 255, green: 250 / 255, blue: 250 / 255, alpha: 1))
            case .lightPink:
                Color(uiColor: UIColor(red: 1, green: 247 / 255, blue: 251 / 255, alpha: 1))
            default: Color(uiColor: UIColor(red: 8 / 255, green: 10 / 255, blue: 9 / 255, alpha: 1))
            }
        }

        var markColor: Color {
            switch self {
            case .classicGreen:
                Color(uiColor: UIColor(red: 93 / 255, green: 245 / 255, blue: 138 / 255, alpha: 1))
            case .lightClassic:
                Color(uiColor: .systemGreen)
            case .darkPink, .lightPink:
                Color(uiColor: UIColor(red: 1, green: 79 / 255, blue: 154 / 255, alpha: 1))
            case .monochromeLight:
                Color(uiColor: UIColor(red: 22 / 255, green: 23 / 255, blue: 22 / 255, alpha: 1))
            case .monochromeDark:
                Color(uiColor: UIColor(white: 245 / 255, alpha: 1))
            }
        }
    }

    static let shared = ShumAppIconStore()

    @Published private(set) var selected: Icon
    @Published private(set) var isChanging = false
    @Published var errorMessage: String?

    private init() {
        let application = UIApplication.shared
        selected = Icon.allCases.first {
            $0.alternateName == application.alternateIconName
        } ?? .classicGreen
    }

    func select(_ icon: Icon) {
        guard !isChanging, selected != icon else { return }
        guard UIApplication.shared.supportsAlternateIcons else {
            errorMessage = "Эта версия iOS не поддерживает смену иконки."
            return
        }

        isChanging = true
        UIApplication.shared.setAlternateIconName(icon.alternateName) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isChanging = false

                if error != nil {
                    self.errorMessage = "Не удалось изменить иконку. Попробуйте ещё раз."
                    return
                }

                self.selected = icon
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
    }
}
