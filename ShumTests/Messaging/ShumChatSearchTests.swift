import Testing
@testable import Shum

struct ShumChatSearchTests {
    @Test func findsNamesWithoutCaseOrAccentSensitivity() {
        #expect(ShumChatSearch.matches("  семен ", name: "Семён Иванов", messages: []))
        #expect(ShumChatSearch.matches("ИВАНОВ семён", name: "Семён Иванов", messages: []))
    }

    @Test func findsEarlierMessagesAndRequiresAllWordsInOneResult() {
        let messages = ["Встречаемся завтра у метро", "До встречи!"]
        #expect(ShumChatSearch.matches("метро завтра", name: "Аня", messages: messages))
        #expect(!ShumChatSearch.matches("метро пятница", name: "Аня", messages: messages))
        #expect(!ShumChatSearch.matches("метро встречи", name: "Аня", messages: messages))
    }

    @Test func emptyQueryDoesNotPopulateResults() {
        #expect(!ShumChatSearch.matches(" \n ", name: "Аня", messages: ["Привет"]))
    }
}
