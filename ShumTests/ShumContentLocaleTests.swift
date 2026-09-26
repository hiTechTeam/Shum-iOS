import Foundation
import Testing
@testable import Shum

/// Relative dates ("5 minutes ago") must use the language the app shows,
/// not a fixed Russian locale.
@Suite("Shum content locale")
struct ShumContentLocaleTests {
    private func relativeYesterday(in locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: Date().addingTimeInterval(-86_400), relativeTo: Date())
    }

    @Test func chosenLanguageDrivesRelativeDates() throws {
        let suite = "test.content-locale.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("en", forKey: ShumLanguageStore.defaultsKey)
        #expect(relativeYesterday(in: ShumLanguageStore.contentLocale(defaults: defaults)) == "1 day ago")

        defaults.set("ru", forKey: ShumLanguageStore.defaultsKey)
        #expect(relativeYesterday(in: ShumLanguageStore.contentLocale(defaults: defaults)) == "1 день назад")

        defaults.set("ja", forKey: ShumLanguageStore.defaultsKey)
        #expect(relativeYesterday(in: ShumLanguageStore.contentLocale(defaults: defaults)).contains("日"))
    }

    @Test func systemLanguageFollowsTheAppLocalization() throws {
        let suite = "test.content-locale.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let expected = Bundle.main.preferredLocalizations.first ?? "en"
        #expect(ShumLanguageStore.contentLocale(defaults: defaults).identifier == expected)
    }
}
