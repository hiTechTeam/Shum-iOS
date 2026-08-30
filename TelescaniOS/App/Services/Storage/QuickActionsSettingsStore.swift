import Combine
import Foundation

final class QuickActionsSettingsStore: ObservableObject {
    static let shared = QuickActionsSettingsStore()

    @Published var isQuickChatEnabled: Bool {
        didSet {
            defaults.set(isQuickChatEnabled, forKey: quickChatKey)
        }
    }

    @Published var isQuickBlockEnabled: Bool {
        didSet {
            defaults.set(isQuickBlockEnabled, forKey: quickBlockKey)
        }
    }

    var hasEnabledActions: Bool {
        isQuickChatEnabled || isQuickBlockEnabled
    }

    private let defaults: UserDefaults
    private let quickChatKey = "telescan.quick-actions.chat"
    private let quickBlockKey = "telescan.quick-actions.block"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isQuickChatEnabled = defaults.bool(forKey: quickChatKey)
        isQuickBlockEnabled = defaults.bool(forKey: quickBlockKey)
    }
}
