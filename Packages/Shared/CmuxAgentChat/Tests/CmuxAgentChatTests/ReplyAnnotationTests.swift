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
///
/// **Structure runs vertically, never horizontally** (Decision 2026-09-04).
/// Six tests here previously pinned the horizontal shape — a marker sharing
/// its line with the quote, a note indented to the marker's width, and a
/// per-line `> ` on a multi-line span. They were correct encodings of a rule
/// the design reversed, and they were deleted with the format rather than
/// after it. What killed the horizontal shape: the preview wraps at 276pt,
/// and a wrapped continuation inherits none of its line's leading marks, so
/// the `> ` vanished and the quoted line read to the agent as instruction —
/// the single confusion the rule existed to prevent.
@Suite("ReplyAnnotation")
struct ReplyAnnotationTests {
    /// Serialization never reads a span's position, so every fixture here
    /// sits at offset 0. Ties keep declaration order, which is what lets
    /// these cases read as the list the author wrote.
    private func annotation(_ quote: String, _ note: String) -> ReplyAnnotation {
        ReplyAnnotation(quote: quote, note: note, range: 0..<quote.count)
    }

    @Test("Two annotations and a whole-message note serialize to the settled format")
    func wireFormat() {
        let set = ReplyAnnotationSet(
            annotations: [annotation("first span", "make this a question"),
                          annotation("second span", "delete this")],
            messageNotes: ["and shorten the whole thing"]
        )

        // The marker owns its line, nothing is indented, and entries are
        // separated by a blank line — every boundary is a line break rather
        // than a leading character, so none of it can be lost to a wrap.
        #expect(set.serialized() == """
        1.
        > "first span"
        make this a question

        2.
        > "second span"
        delete this

        ---
        and shorten the whole thing
        """)
    }

    @Test("A span alone, with no whole-message note, carries no rule")
    func noTrailingRuleWithoutMessageNotes() {
        let set = ReplyAnnotationSet(annotations: [annotation("a span", "fix it")])

        #expect(set.serialized() == """
        1.
        > "a span"
        fix it
        """)
        #expect(!set.serialized().contains("---"))
    }

    @Test("A cross-block span takes a fence, not a per-line blockquote")
    func crossBlockSpanTakesAFence() {
        let set = ReplyAnnotationSet(
            annotations: [annotation("tail of one paragraph\nhead of the next", "delete this")]
        )

        // A fence needs no per-line mark, so no line of the span can lose its
        // framing to a wrap — which is exactly what the retired `> ` on every
        // continuation line could not survive.
        #expect(set.serialized() == """
        1.
        ```
        tail of one paragraph
        head of the next
        ```
        delete this
        """)
    }

    @Test("A long single-line quote takes a fence, because the trigger is width and not newlines")
    func longSingleLineQuoteTakesAFence() {
        // No newline anywhere in it, and it still cannot fit one line in the
        // preview. This is the case that makes the rule *fits on one line*
        // rather than *contains a newline*.
        let long = String(repeating: "wide ", count: 60).trimmingCharacters(in: .whitespaces)
        let set = ReplyAnnotationSet(annotations: [annotation(long, "shorten it")])

        #expect(!long.contains("\n"))
        #expect(set.serialized() == """
        1.
        ```
        \(long)
        ```
        shorten it
        """)
    }

    @Test("A quote at the budget stays inline, and one character past it takes a fence")
    func inlineQuoteBudgetIsTheBoundary() {
        let atBudget = String(repeating: "x", count: ReplyAnnotationSet.inlineQuoteCharacterBudget)
        let overBudget = atBudget + "x"

        #expect(ReplyAnnotationSet(annotations: [annotation(atBudget, "n")])
            .serialized().contains("> \"\(atBudget)\""))
        #expect(ReplyAnnotationSet(annotations: [annotation(overBudget, "n")])
            .serialized().contains("```\n\(overBudget)\n```"))
    }

    @Test("A fence opens with one more backtick than the longest run inside it")
    func fenceNestsByBacktickCount() {
        // Per CommonMark: a fence must be longer than any run of backticks in
        // its content, or the span's own fence closes ours early and the rest
        // of the prompt falls out of the quote.
        let set = ReplyAnnotationSet(
            annotations: [annotation("before\n```swift\nlet x = 1\n```\nafter", "explain this")]
        )

        #expect(set.serialized() == """
        1.
        ````
        before
        ```swift
        let x = 1
        ```
        after
        ````
        explain this
        """)
    }

    @Test("The marker owns its line at every index, so a 10th entry needs no alignment")
    func markerOwnsItsLineAtEveryIndex() {
        let set = ReplyAnnotationSet(
            annotations: (1...10).map { annotation("span \($0)", "note \($0)") }
        )
        let lines = set.serialized().split(separator: "\n", omittingEmptySubsequences: false)

        // Nothing aligns to the marker's width, which is what makes the
        // 1-to-9 and 10-plus cases one format rather than two.
        #expect(lines[0] == "1.")
        #expect(lines[1] == #"> "span 1""#)
        #expect(lines[2] == "note 1")
        #expect(lines[36] == "10.")
        #expect(lines[37] == #"> "span 10""#)
        #expect(lines[38] == "note 10")
        #expect(!set.serialized().split(separator: "\n").contains { $0.hasPrefix(" ") })
    }

    /// A highlight with no instruction is carried, and keeps its number.
    ///
    /// It used to be dropped, which renumbered everything after it — so a
    /// footer row reading `2.` pasted as `1.` and the manifest lied about the
    /// one thing it exists to state. Paste lands in a composer, so an
    /// unwritten note is a sentence the user is about to finish there, not a
    /// mistake to be filtered out (Tom, dogfood 2026-09-06).
    @Test("A highlight with no instruction is carried, quote only, and keeps its number")
    func emptyNoteKeepsItsPlace() {
        let set = ReplyAnnotationSet(
            annotations: [annotation("highlighted, never written about", "   "),
                          annotation("second span", "delete this")]
        )

        #expect(set.serialized() == """
        1.
        > "highlighted, never written about"

        2.
        > "second span"
        delete this
        """)
        // The footer's numbers and the payload's numbers are the same numbers.
        #expect(set.numbered.map(\.number) == [1, 2])
    }

    /// The two buttons gate on two different things, and that is the point.
    ///
    /// `Paste` is off only when there is nothing to put anywhere. `Paste &
    /// Send` still wants an instruction, because it has no composer step in
    /// which to add one.
    @Test("Paste gates on emptiness; Paste & Send gates on an instruction")
    func deliverability() {
        let nothing = ReplyAnnotationSet()
        let markedOnly = ReplyAnnotationSet(annotations: [annotation("span", "")])
        let written = ReplyAnnotationSet(annotations: [annotation("span", "do it")])

        #expect(nothing.isEmpty)
        #expect(!markedOnly.isEmpty)
        #expect(!written.isEmpty)
        #expect(ReplyAnnotationSet(messageNotes: ["  ", ""]).isEmpty)
        #expect(!ReplyAnnotationSet(messageNotes: ["do it"]).isEmpty)

        #expect(!nothing.isDeliverable)
        #expect(!markedOnly.isDeliverable)
        #expect(!ReplyAnnotationSet(messageNotes: ["  ", ""]).isDeliverable)
        #expect(written.isDeliverable)
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

    @Test("A multi-line instruction keeps its own lines, with nothing indented under the marker")
    func multiLineNoteKeepsItsLines() {
        let set = ReplyAnnotationSet(
            annotations: [annotation("a span", "make this a question\nand keep it short")]
        )

        #expect(set.serialized() == """
        1.
        > "a span"
        make this a question
        and keep it short
        """)
    }
}
