import BitFoundation
import Foundation
import Testing
@testable import Shum

@Suite("Navigation tap reentrancy")
struct ShumNavigationPathTests {
    private let alice = ShumPeer(id: PeerID(str: "1111111111111111"), name: "Аня", lastConnected: .distantPast)
    private let bob = ShumPeer(id: PeerID(str: "2222222222222222"), name: "Борис", lastConnected: .distantPast)

    @Test func rapidTapsOnSameOrDifferentRowsOpenOneConversation() {
        var path: [ShumUIRoute] = []
        path.push(.conversation(alice))
        var updated = alice
        updated.lastConnected = Date()
        path.push(.conversation(updated))
        path.push(.conversation(bob))
        #expect(path == [.conversation(alice)])
    }

    @Test func returningToListAllowsImmediateReopening() {
        var path: [ShumUIRoute] = []
        path.push(.conversation(alice))
        path.removeLast()
        path.push(.conversation(alice))
        #expect(path == [.conversation(alice)])
    }

    @Test func requestListRemainsBelowSingleConversation() {
        var path: [ShumUIRoute] = []
        path.push(.requests)
        path.push(.requests)
        path.push(.conversation(alice))
        path.push(.conversation(alice))
        #expect(path == [.requests, .conversation(alice)])
    }

    @Test func encounterCardCannotPushTwoChatsAndWorksAfterBack() {
        var path: [ShumProfileRoute] = []
        path.push(.encounters)
        path.push(.encounters)
        path.push(.conversation(alice))
        path.push(.conversation(bob))
        #expect(path == [.encounters, .conversation(alice)])
        path.removeLast()
        path.push(.conversation(bob))
        #expect(path == [.encounters, .conversation(bob)])
    }
}
