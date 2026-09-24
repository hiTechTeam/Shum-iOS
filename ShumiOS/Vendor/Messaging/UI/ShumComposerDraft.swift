import Foundation

struct ShumComposerDraft {
    private(set) var text = ""
    private(set) var revision = UUID()

    mutating func update(_ text: String, from editorRevision: UUID) {
        // A retired editor may still deliver an autocorrection/composition update.
        guard editorRevision == revision else { return }
        self.text = text
    }

    mutating func clearAfterSending() {
        revision = UUID()
        text = ""
    }
}
