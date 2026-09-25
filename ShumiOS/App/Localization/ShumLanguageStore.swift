import Foundation
import SwiftUI
import UIKit

@MainActor
final class ShumLanguageStore: ObservableObject {
    enum Language: String, CaseIterable, Identifiable {
        case system
        case russian = "ru"
        case english = "en"
        case spanish = "es"
        case simplifiedChinese = "zh-Hans"
        case hindi = "hi"
        case french = "fr"
        case japanese = "ja"
        case portugueseBrazil = "pt-BR"
        case arabic = "ar"
        case korean = "ko"

        var id: String { rawValue }

        var nativeTitle: String {
            switch self {
            case .system: "Системный язык".localized
            case .russian: "Русский"
            case .english: "English"
            case .spanish: "Español"
            case .simplifiedChinese: "简体中文"
            case .hindi: "हिन्दी"
            case .french: "Français"
            case .japanese: "日本語"
            case .portugueseBrazil: "Português (Brasil)"
            case .arabic: "العربية"
            case .korean: "한국어"
            }
        }

        var localeIdentifier: String {
            self == .system ? Locale.autoupdatingCurrent.identifier : rawValue
        }
    }

    static let shared = ShumLanguageStore()
    nonisolated static let defaultsKey = "shum.application.language"

    @Published private(set) var selected: Language

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selected = defaults.string(forKey: Self.defaultsKey)
            .flatMap(Language.init(rawValue:))
            ?? .system
    }

    var locale: Locale {
        selected == .system
            ? .autoupdatingCurrent
            : Locale(identifier: selected.localeIdentifier)
    }

    /// Keep navigation, gestures and custom controls in their established
    /// positions. Arabic text still uses its natural bidirectional rendering.
    var layoutDirection: LayoutDirection { .leftToRight }

    var selectedTitle: String { selected.nativeTitle }

    func select(_ language: Language) {
        guard selected != language else { return }
        selected = language
        if language == .system {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(language.rawValue, forKey: Self.defaultsKey)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    nonisolated static func localizedString(forKey key: String) -> String {
        guard let code = UserDefaults.standard.string(forKey: defaultsKey),
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main.localizedString(forKey: key, value: nil, table: nil)
        }
        return bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}
