import Foundation
import Testing
@testable import Shum

struct ShumChatProtectionStateTests {
    @Test func storedRecipientKeyProtectsOfflineMessagesWithoutLiveSession() {
        #expect(ShumChatProtectionState(isReady: true, isArchive: false,
            hasRecipientKey: true, session: .none, hasSessionKey: false) == .encrypted)
        #expect(ShumChatProtectionState(isReady: true, isArchive: false,
            hasRecipientKey: true, session: .failed(TestError()), hasSessionKey: false) == .encrypted)
    }

    @Test func bluetoothConnectionAloneDoesNotClaimEncryption() {
        for session in [LazyHandshakeState.none, .handshakeQueued, .handshaking, .established] {
            #expect(ShumChatProtectionState(isReady: true, isArchive: false,
                hasRecipientKey: false, session: session, hasSessionKey: false) == .preparing)
        }
        #expect(ShumChatProtectionState(isReady: true, isArchive: false,
            hasRecipientKey: false, session: .established, hasSessionKey: true) == .encrypted)
    }

    @Test func failedAndRetiredRuntimesDoNotClaimActiveProtection() {
        #expect(ShumChatProtectionState(isReady: false, isArchive: false,
            hasRecipientKey: true, session: .established, hasSessionKey: true) == .unavailable)
        #expect(ShumChatProtectionState(isReady: true, isArchive: false,
            hasRecipientKey: false, session: .failed(TestError()), hasSessionKey: false) == .unavailable)
    }

    @Test func legacyHistoryIsNotPresentedAsAnActiveEncryptedChat() {
        #expect(ShumChatProtectionState(isReady: true, isArchive: true,
            hasRecipientKey: true, session: .established, hasSessionKey: true) == .archive)
    }

    private struct TestError: Error {}
}
