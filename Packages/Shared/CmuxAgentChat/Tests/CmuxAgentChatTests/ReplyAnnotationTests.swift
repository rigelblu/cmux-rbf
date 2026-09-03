import Foundation
import Testing

@testable import CmuxAgentChat

/// Serializing a marked-up message into the prompt the agent receives.
///
/// The wire format is a contract with every agent that learns it, so each
/// case here is a way the prompt could still look reasonable and mean
/// something else: an anchor that reads as instruction, an instruction that
/// reads as quoted text, or the message handed back to an agent that
/// already holds it.
@Suite("ReplyAnnotation")
struct ReplyAnnotationTests {
    private func annotation(_ quote: String, _ note: String) -> ReplyAnnotation {
        ReplyAnnotation(quote: quote, note: note)
    }

    @Test("Two annotations and a whole-message note serialize to the settled format")
    func wireFormat() {
        let set = ReplyAnnotationSet(
            annotations: [annotation("first span", "make this a question"),
                          annotation("second span", "delete this")],
            messageNotes: ["and shorten the whole thing"]
        )

        #expect(set.serialized() == """
        1. > "first span"
           make this a question
        2. > "second span"
           delete this
        ---
        and shorten the whole thing
        """)
    }

    @Test("A span alone, with no whole-message note, carries no rule")
    func noTrailingRuleWithoutMessageNotes() {
        let set = ReplyAnnotationSet(annotations: [annotation("a span", "fix it")])

        #expect(set.serialized() == """
        1. > "a span"
           fix it
        """)
        #expect(!set.serialized().contains("---"))
    }

    @Test("A cross-block span stays one entry, and every line stays inside the quote")
    func crossBlockSpanKeepsItsBlockquote() {
        let set = ReplyAnnotationSet(
            annotations: [annotation("tail of one paragraph\nhead of the next", "delete this")]
        )

        // The second line must carry its own `>`. Without it the line reads
        // to the agent as instruction rather than as the span being quoted.
        #expect(set.serialized() == """
        1. > "tail of one paragraph
           > head of the next"
           delete this
        """)
    }

    @Test("Continuation indent follows the marker's width, so a 10th entry still nests")
    func indentTracksMarkerWidth() {
        let set = ReplyAnnotationSet(
            annotations: (1...10).map { annotation("span \($0)", "note \($0)") }
        )
        let lines = set.serialized().split(separator: "\n", omittingEmptySubsequences: false)

        #expect(lines[1] == "   note 1")
        #expect(lines[18] == "10. > \"span 10\"")
        #expect(lines[19] == "    note 10")
    }

    @Test("A highlight with no instruction is dropped, and does not consume a number")
    func emptyNoteIsNotDeliverable() {
        let set = ReplyAnnotationSet(
            annotations: [annotation("highlighted, never written about", "   "),
                          annotation("second span", "delete this")]
        )

        #expect(set.serialized() == """
        1. > "second span"
           delete this
        """)
    }

    @Test("An empty draft is not deliverable, so the buttons have something to gate on")
    func deliverability() {
        #expect(!ReplyAnnotationSet().isDeliverable)
        #expect(!ReplyAnnotationSet(annotations: [annotation("span", "")]).isDeliverable)
        #expect(!ReplyAnnotationSet(messageNotes: ["  ", ""]).isDeliverable)
        #expect(ReplyAnnotationSet(annotations: [annotation("span", "do it")]).isDeliverable)
        #expect(ReplyAnnotationSet(messageNotes: ["do it"]).isDeliverable)
    }

    @Test("A whole-message note with no annotations carries no rule either")
    func messageNoteAloneHasNoRule() {
        let set = ReplyAnnotationSet(messageNotes: ["rewrite the ending"])

        #expect(set.serialized() == "rewrite the ending")
    }

    @Test("The quote is verbatim: quotation marks inside a span are not escaped")
    func quoteIsVerbatim() {
        let set = ReplyAnnotationSet(
            annotations: [annotation(#"he said "no" twice"#, "soften this")]
        )

        // The span is what the user saw. Escaping would hand the agent text
        // that was never on screen.
        #expect(set.serialized().contains(#"> "he said "no" twice""#))
    }

    @Test("A multi-line instruction stays indented under its own entry")
    func multiLineNoteStaysNested() {
        let set = ReplyAnnotationSet(
            annotations: [annotation("a span", "make this a question\nand keep it short")]
        )

        #expect(set.serialized() == """
        1. > "a span"
           make this a question
           and keep it short
        """)
    }
}
