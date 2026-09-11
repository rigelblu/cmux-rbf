import Foundation
import Testing

@testable import CmuxAgentChat

/// Applies `label` to a note written as a template: `|` marks the caret, and
/// `[` … `]` marks a selection. Returns the resulting note with `|` at the
/// caret the insertion leaves behind, so each case reads as one before/after
/// pair.
private func insert(_ label: String, into template: String) -> String {
    var note = ""
    var selection = NSRange(location: 0, length: 0)
    var openAt: Int?
    for character in template {
        let here = (note as NSString).length
        switch character {
        case "|": selection = NSRange(location: here, length: 0)
        case "[": openAt = here
        case "]": selection = NSRange(location: openAt ?? here, length: here - (openAt ?? here))
        default: note.append(character)
        }
    }
    let insertion = ReplyLabelInsertion.apply(label: label, to: note, selection: selection)
    let result = insertion.applied(to: note) as NSString
    return result.replacingCharacters(in: NSRange(location: insertion.caretLocation, length: 0), with: "|")
}

/// Scenario C of `cm-69.3` — the rule both insertion paths apply.
@Suite("ReplyLabelInsertion")
struct ReplyLabelInsertionTests {
    @Test func midNoteBeforeASpacePadsOnlyTheLeft() {
        // The caret lands before the existing space, so the next letter types
        // into `lgtm`'s end — `needs lgtmX work` — which is what the caret
        // position means, not a bug.
        #expect(insert("lgtm", into: "needs| work") == "needs lgtm| work")
    }

    /// Focusing a note field selects all of it, and that selection is what a
    /// chip click finds when the note was opened and not clicked into. A
    /// label must never wipe a written note, so a whole-note selection is
    /// treated as a caret at the end (cold code review, 2026-09-11).
    @Test func aWholeNoteSelectionAppendsInsteadOfReplacing() {
        #expect(insert("lgtm", into: "[needs work]") == "needs work lgtm|")
    }

    @Test func atTheEndAfterAWordPadsTheLeft() {
        #expect(insert("lgtm", into: "needs work|") == "needs work lgtm|")
    }

    @Test func atTheEndAfterASpaceDoesNotDoubleIt() {
        #expect(insert("lgtm", into: "needs work |") == "needs work lgtm|")
    }

    @Test func anEmptyNoteGetsTheBareLabel() {
        #expect(insert("lgtm", into: "|") == "lgtm|")
    }

    @Test func atTheStartBeforeAWordPadsTheRight() {
        #expect(insert("lgtm", into: "|work") == "lgtm |work")
    }

    @Test func aSelectionIsReplaced() {
        #expect(insert("lgtm", into: "needs [work]") == "needs lgtm|")
    }

    @Test func aSelectionInsideWordsIsPaddedOnBothSides() {
        #expect(insert("lgtm", into: "needs[ ]work") == "needs lgtm |work")
    }

    @Test func newlinesCountAsWhitespace() {
        #expect(insert("lgtm", into: "first line\n|") == "first line\nlgtm|")
    }

    /// UTF-16, because that is what the field editor reports. A `Character`
    /// count would put the caret one short after the emoji.
    @Test func anEmojiBeforeTheCaretKeepsTheCaretInPlace() {
        #expect(insert("lgtm", into: "ok 👍|") == "ok 👍 lgtm|")
    }

    @Test func aSelectionPastTheEndIsClamped() {
        let insertion = ReplyLabelInsertion.apply(
            label: "lgtm", to: "ab", selection: NSRange(location: 1, length: 40)
        )
        #expect(insertion.applied(to: "ab") == "a lgtm")
    }
}
