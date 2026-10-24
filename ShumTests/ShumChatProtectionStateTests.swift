import Foundation
import Testing
@testable import Shum

struct ShumChatProtectionStateTests {
    @Test func theContactsSignedCardProtectsTheChat() {
        #expect(ShumChatProtectionState(isReady: true, isArchive: false, hasRecipientKey: true) == .encrypted)
    }

    @Test func withoutTheCardTheChatIsStillBeingPrepared() {
        #expect(ShumChatProtectionState(isReady: true, isArchive: false, hasRecipientKey: false) == .preparing)
    }

    @Test func failedAndRetiredRuntimesDoNotClaimActiveProtection() {
        #expect(ShumChatProtectionState(isReady: false, isArchive: false, hasRecipientKey: true) == .unavailable)
    }

    @Test func legacyHistoryIsNotPresentedAsAnActiveEncryptedChat() {
        #expect(ShumChatProtectionState(isReady: true, isArchive: true, hasRecipientKey: true) == .archive)
    }
}
