import Foundation

/// Application runtime configuration loaded from Info.plist
enum AppConfig {

    static let skipRegistration = false

    /// Base API origin
    static let apiOrigin: String = {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "API_ORIGIN"
        ) as? String else {
            fatalError("API_ORIGIN is missing in Info.plist")
        }
        return value
    }()

    /// Telegram bot link
    static let telescanBot: String = {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: "TELESCAN_BOT"
        ) as? String else {
            fatalError("TELESCAN_BOT is missing in Info.plist")
        }
        return value
    }()

}
