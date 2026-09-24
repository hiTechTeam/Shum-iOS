import Testing
@testable import Shum

struct ShumComposerDraftTests {
    @Test func delayedKeyboardUpdateCannotRestoreSentText() {
        var draft = ShumComposerDraft()
        let editor = draft.revision
        draft.update("Привет\nКак дела? 👋", from: editor)

        draft.clearAfterSending()
        draft.update("Привет\nКак дела? 👋", from: editor)

        #expect(draft.text.isEmpty)
        #expect(draft.revision != editor)
    }

    @Test func oldEditorCannotOverwriteNextMessage() {
        var draft = ShumComposerDraft()
        let oldEditor = draft.revision
        draft.update("Первое", from: oldEditor)
        draft.clearAfterSending()
        draft.update("Второе", from: draft.revision)

        draft.update("Первое!", from: oldEditor)
        draft.update("", from: oldEditor)

        #expect(draft.text == "Второе")
    }

    @Test func identicalMessagesCanBeEnteredAgain() {
        var draft = ShumComposerDraft()
        let firstEditor = draft.revision
        draft.update("Да", from: firstEditor)
        draft.clearAfterSending()
        let secondEditor = draft.revision
        draft.update("Да", from: secondEditor)
        #expect(draft.text == "Да")

        draft.clearAfterSending()
        draft.update("Да", from: firstEditor)
        draft.update("Да", from: secondEditor)
        #expect(draft.text.isEmpty)
    }
}
