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
        for turnEnded in [true, false] {
            #expect(
                ReplyDeliveryGate.canDeliver(s, submit: false, turnEnded: turnEnded)
                    == ReplyDeliveryGate.canPaste(s)
            )
            #expect(
                ReplyDeliveryGate.canDeliver(s, submit: true, turnEnded: turnEnded)
                    == ReplyDeliveryGate.canSend(s, turnEnded: turnEnded)
            )
        }
    }
}
