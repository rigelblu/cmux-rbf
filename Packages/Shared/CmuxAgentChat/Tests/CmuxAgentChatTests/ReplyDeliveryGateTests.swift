import Foundation
import Testing

@testable import CmuxAgentChat

/// The one rule two entrypoints both read.
///
/// These exist because the rule was previously written out at each call site
/// and the copies disagreed — an *enabled* `Paste` that typed nothing. The
/// value of a test here is not that the logic is hard; it is that neither the
/// SwiftUI `.disabled` nor `ReplyPanelStore.deliver` can be unit-tested, so
/// before this type the rule had no reachable assertion at all.
@Suite("ReplyDeliveryGate")
struct ReplyDeliveryGateTests {
    private func mark(quote: String = "a span", note: String = "") -> ReplyAnnotation {
        ReplyAnnotation(quote: quote, note: note, range: 0..<6)
    }

    private func set(_ annotations: [ReplyAnnotation]) -> ReplyAnnotationSet {
        var s = ReplyAnnotationSet()
        for a in annotations { s.insert(a) }
        return s
    }

    @Test("Nothing marked means nothing to paste")
    func emptySetPastesNothing() {
        #expect(!ReplyDeliveryGate.canPaste(ReplyAnnotationSet()))
        #expect(!ReplyDeliveryGate.canSend(ReplyAnnotationSet(), turnEnded: true))
    }

    /// The rule Tom set on 2026-09-06: *"I don't see a reason to disable paste
    /// any time — the user might want to edit/enter the text in the agent
    /// terminal."* A mark with no note is a complete thought.
    @Test("A mark with no note still pastes, and still does not send")
    func noteLessMarkPastesButDoesNotSend() {
        let s = set([mark(note: "")])
        #expect(ReplyDeliveryGate.canPaste(s))
        #expect(!ReplyDeliveryGate.canSend(s, turnEnded: true))
    }

    @Test("A written note sends once the turn has ended")
    func writtenNoteSendsAfterTheTurn() {
        let s = set([mark(note: "make this a question")])
        #expect(ReplyDeliveryGate.canPaste(s))
        #expect(ReplyDeliveryGate.canSend(s, turnEnded: true))
    }

    /// The trust case: typing into a running agent can answer a permission
    /// prompt with your notes.
    @Test("A written note does not send while the turn is still running")
    func writtenNoteHoldsWhileTheTurnRuns() {
        let s = set([mark(note: "make this a question")])
        #expect(ReplyDeliveryGate.canPaste(s), "a paste is never held by the turn")
        #expect(!ReplyDeliveryGate.canSend(s, turnEnded: false))
    }

    /// `canDeliver` is the store's guard expressed once. If it ever disagrees
    /// with the two predicates the buttons read, the panel offers something
    /// the store refuses — which is the exact defect this type exists to make
    /// unreachable.
    @Test(
        "The store's guard and the buttons' predicates cannot disagree",
        arguments: [
            ReplyAnnotationSet(),
            ReplyAnnotationSet(annotations: [ReplyAnnotation(quote: "a span", note: "", range: 0..<6)]),
            ReplyAnnotationSet(annotations: [ReplyAnnotation(quote: "a span", note: "fix", range: 0..<6)]),
        ]
    )
    func storeGuardMatchesTheButtons(_ s: ReplyAnnotationSet) {
        for editedText in [nil, "", " \n", "x"] as [String?] {
            for turnEnded in [true, false] {
                #expect(
                    ReplyDeliveryGate.canDeliver(s, editedText: editedText, submit: false, turnEnded: turnEnded)
                        == ReplyDeliveryGate.canPaste(s, editedText: editedText)
                )
                #expect(
                    ReplyDeliveryGate.canDeliver(s, editedText: editedText, submit: true, turnEnded: turnEnded)
                        == ReplyDeliveryGate.canSend(s, editedText: editedText, turnEnded: turnEnded)
                )
            }
        }
    }

    // MARK: - The edited paste preview (`#cm-93`)

    /// An edited box is what gets sent, so the box — not the marks — decides.
    /// Blank means nothing to send (Tom, 2026-09-14, Q2).
    @Test("A blank edited box is refused both ways, even with a written note", arguments: ["", "   ", " \n\t"])
    func blankEditedBoxIsRefused(_ blank: String) {
        let s = set([mark(note: "make this a question")])
        #expect(!ReplyDeliveryGate.canPaste(s, editedText: blank))
        #expect(!ReplyDeliveryGate.canSend(s, editedText: blank, turnEnded: true))
    }

    /// Tom, 2026-09-14: text you edited in the box is the instruction, so
    /// `Paste & Send` no longer also wants a written note.
    @Test("An edited box sends once the turn has ended, even with no written note")
    func editedBoxIsTheInstruction() {
        let s = set([mark(note: "")])
        #expect(ReplyDeliveryGate.canPaste(s, editedText: "please reword this"))
        #expect(ReplyDeliveryGate.canSend(s, editedText: "please reword this", turnEnded: true))
    }

    @Test("An edited box still does not send while the turn is running")
    func editedBoxHoldsWhileTheTurnRuns() {
        let s = set([mark(note: "")])
        #expect(ReplyDeliveryGate.canPaste(s, editedText: "please reword this"))
        #expect(!ReplyDeliveryGate.canSend(s, editedText: "please reword this", turnEnded: false))
    }

    @Test("No edited text keeps today's rule on the marks")
    func noEditedTextKeepsTheMarksRule() {
        let noteLess = set([mark(note: "")])
        #expect(ReplyDeliveryGate.canPaste(noteLess, editedText: nil))
        #expect(!ReplyDeliveryGate.canSend(noteLess, editedText: nil, turnEnded: true))
        #expect(!ReplyDeliveryGate.canPaste(ReplyAnnotationSet(), editedText: nil))
    }
}
