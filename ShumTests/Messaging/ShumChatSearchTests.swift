import Foundation
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

    @Test func pullingMovesTheExpandedHeaderAsOneGroup() {
        let layout = ShumChatHeaderLayout(offset: -80)
        #expect(layout.pull == 80)
        #expect(layout.searchHeight == 54)
        #expect(layout.fieldHeight == 44)
        #expect(layout.contentOpacity == 1)
    }

    @Test func searchCollapsesBeforeFoldersStayPinned() {
        let partial = ShumChatHeaderLayout(offset: 30)
        #expect(partial.searchHeight == 24)
        #expect(partial.pull == 0)
        #expect(partial.fieldHeight > 0)
        #expect(partial.contentOpacity == 0)
        let collapsed = ShumChatHeaderLayout(offset: 500)
        #expect(collapsed.searchHeight == 0)
        #expect(collapsed.fieldHeight == 0)
        #expect(collapsed.fieldOpacity == 0)
        #expect(collapsed.pull == 0)
    }

    @Test func emptyQueryDoesNotPopulateResults() {
        #expect(!ShumChatSearch.matches(" \n ", name: "Аня", messages: ["Привет"]))
    }
}
