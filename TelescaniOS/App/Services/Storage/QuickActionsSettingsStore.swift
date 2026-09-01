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

    @Published var isQuickClearEnabled: Bool {
        didSet {
            defaults.set(isQuickClearEnabled, forKey: quickClearKey)
        }
    }

    var hasEnabledActions: Bool {
        isQuickChatEnabled || isQuickClearEnabled || isQuickBlockEnabled
    }

    private let defaults: UserDefaults
    private let quickChatKey = "telescan.quick-actions.chat"
    private let quickClearKey = "telescan.quick-actions.clear"
    private let quickBlockKey = "telescan.quick-actions.block"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isQuickChatEnabled = defaults.bool(forKey: quickChatKey)
        isQuickClearEnabled = defaults.bool(forKey: quickClearKey)
        isQuickBlockEnabled = defaults.bool(forKey: quickBlockKey)
    }

    func reset() {
        isQuickChatEnabled = false
        isQuickClearEnabled = false
        isQuickBlockEnabled = false
    }
}
