import Foundation
import Testing

@testable import CmuxAgentChat

private func annotation(_ quote: String, _ note: String, at start: Int) -> ReplyAnnotation {
    ReplyAnnotation(quote: quote, note: note, range: start..<(start + quote.count))
}

/// Five spans in document order, far enough apart that none of them touch.
private func fiveAnnotations() -> ReplyAnnotationSet {
    ReplyAnnotationSet(annotations: [
        annotation("alpha", "first note", at: 0),
        annotation("bravo", "second note", at: 20),
        annotation("charlie", "third note", at: 40),
        annotation("delta", "fourth note", at: 60),
        annotation("echo", "fifth note", at: 80),
    ])
}

/// The number a mark carries is its **position**, recomputed on every change.
///
/// The moment it stops matching position it stops doing its only job, and
/// the footer stops matching paste order — which is the manifest's whole
/// purpose. Nothing may persist a note's number.
@Suite("ReplyAnnotationSetRenumbering")
struct ReplyAnnotationSetRenumberingTests {
    @Test("Removing the second of five renumbers every survivor after it")
    func removingFromTheMiddleRenumbers() {
        var set = fiveAnnotations()
        let removed = set.annotations[1].id
        set.remove(id: removed)

        #expect(set.numbered.map(\.number) == [1, 2, 3, 4])
        #expect(set.numbered.map(\.quote) == ["alpha", "charlie", "delta", "echo"])

        let serialized = set.serialized()
        #expect(serialized.contains("1.\n> \"alpha\""))
        #expect(serialized.contains("2.\n> \"charlie\""))
        #expect(serialized.contains("4.\n> \"echo\""))
        #expect(!serialized.contains("5."))
        #expect(!serialized.contains("bravo"))
    }

    @Test("Removing the first renumbers all four survivors")
    func removingTheHeadRenumbers() {
        var set = fiveAnnotations()
        set.remove(id: set.annotations[0].id)

        #expect(set.numbered.map(\.number) == [1, 2, 3, 4])
        #expect(set.numbered.map(\.quote) == ["bravo", "charlie", "delta", "echo"])
        #expect(set.serialized().contains("1.\n> \"bravo\""))
    }

    @Test("Removing the last renumbers nobody, which is why it cannot catch a stored index")
    func removingTheTailRenumbersNothing() {
        var set = fiveAnnotations()
        set.remove(id: set.annotations[4].id)

        // A stored index survives this case unchanged. It is here to say so
        // out loud: this is the one removal that proves nothing about
        // renumbering, and a suite testing only it would go green on the bug.
        #expect(set.numbered.map(\.number) == [1, 2, 3, 4])
        #expect(set.numbered.map(\.quote) == ["alpha", "bravo", "charlie", "delta"])
    }

    @Test("The markers a message renders and the rows a footer renders are one numbering")
    func markersAndRowsShareOneNumbering() {
        var set = fiveAnnotations()
        set.remove(id: set.annotations[1].id)

        // The footer's rows are `numbered` too — one derivation, so
        // there is no second place for the two to disagree in the same
        // snapshot. A view holding its own counter is what this forbids.
        let markers = set.numbered
        for (offset, marker) in markers.enumerated() {
            #expect(marker.number == offset + 1)
        }
        #expect(markers.count == set.annotations.count)
    }

    @Test("A note-less entry holds its number in the footer *and* in the payload")
    func aMarkWithNoNoteStillCarriesItsNumber() {
        // The number appears on the mark the moment the *mark* exists, not
        // when a note is typed into it. It used to be dropped at
        // serialization, so the footer said `2.` while the paste said `1.` —
        // this test asserted that mismatch as intended behaviour, which is
        // how it survived. One numbering now, screen and payload.
        let set = ReplyAnnotationSet(annotations: [
            annotation("unwritten", "", at: 0),
            annotation("written", "do this", at: 20),
        ])

        #expect(set.numbered.map(\.number) == [1, 2])
        #expect(set.serialized() == """
        1.
        > "unwritten"

        2.
        > "written"
        do this
        """)
    }
}

/// No undo is defensible only while removal takes exactly one thing.
///
/// If removing one note can disturb another, the loss stops being "a
/// sentence typed seconds ago about a phrase still on screen" and the
/// no-undo decision stops holding.
@Suite("ReplyAnnotationSetRemoval")
struct ReplyAnnotationSetRemovalTests {
    @Test("Removing one annotation leaves the other four byte-identical")
    func removalTakesNothingElse() {
        var set = fiveAnnotations()
        let survivorsBefore = set.annotations.filter { $0.id != set.annotations[1].id }

        set.remove(id: set.annotations[1].id)

        // Compared by value, not by count: a count check passes even if a
        // neighbour was re-anchored or its note rewritten.
        #expect(set.annotations == survivorsBefore)
    }

    @Test("Removing an annotation leaves the whole-message block untouched")
    func removalLeavesMessageNotes() {
        var set = fiveAnnotations()
        set.messageNotes = ["and shorten the whole thing"]

        set.remove(id: set.annotations[2].id)

        #expect(set.messageNotes == ["and shorten the whole thing"])
        #expect(set.serialized().hasSuffix("---\nand shorten the whole thing"))
    }

    @Test("Writing a note leaves the span, the position and every neighbour alone")
    func updatingANoteTouchesOnlyThatNote() {
        var set = fiveAnnotations()
        let target = set.annotations[2]

        set.updateNote(id: target.id, note: "rewritten")

        #expect(set.annotations[2].note == "rewritten")
        #expect(set.annotations[2].quote == target.quote)
        #expect(set.annotations[2].range == target.range)
        #expect(set.numbered.map(\.number) == [1, 2, 3, 4, 5])
        #expect(set.annotations.map(\.note)
            == ["first note", "second note", "rewritten", "fourth note", "fifth note"])
    }

    @Test("Writing a note against an id that is not in the set changes nothing")
    func updatingAnUnknownIDIsANoOp() {
        var set = fiveAnnotations()
        let before = set

        set.updateNote(id: UUID(), note: "nowhere")

        #expect(set == before)
    }

    @Test("Removing an id that is not in the set changes nothing")
    func removingAnUnknownIDIsANoOp() {
        var set = fiveAnnotations()
        let before = set

        set.remove(id: UUID())

        #expect(set == before)
    }
}

/// Two washes stacked on one phrase cannot be read as two marks, so an
/// overlapping selection is refused rather than merged or widened.
@Suite("ReplyAnnotationOverlap")
struct ReplyAnnotationOverlapTests {
    /// The standing annotation every case below is tested against.
    private func existing() -> ReplyAnnotationSet {
        ReplyAnnotationSet(annotations: [
            ReplyAnnotation(quote: "one answer is one reply", note: "check this", range: 10..<33),
        ])
    }

    @Test("A selection wholly inside an existing annotation is refused")
    func insideIsRefused() {
        var set = existing()
        let before = set

        #expect(set.insert(ReplyAnnotation(quote: "is one", note: "", range: 21..<27)) == false)
        #expect(set == before)
    }

    @Test("A selection overlapping the head is refused")
    func headOverlapIsRefused() {
        var set = existing()
        let before = set

        #expect(set.insert(ReplyAnnotation(quote: "the one answer", note: "", range: 0..<20)) == false)
        #expect(set == before)
    }

    @Test("A selection overlapping the tail is refused")
    func tailOverlapIsRefused() {
        var set = existing()
        let before = set

        #expect(set.insert(ReplyAnnotation(quote: "reply, and", note: "", range: 28..<40)) == false)
        #expect(set == before)
    }

    @Test("A selection that touches the boundary without sharing a character is allowed")
    func adjacentIsAllowed() {
        var set = existing()

        // The check is shared characters, not adjacency: `..<33` ends where
        // `33..<` begins and they share nothing. Refusing this would make
        // the phrase immediately after a mark unmarkable.
        #expect(set.insert(ReplyAnnotation(quote: " and then", note: "", range: 33..<42)) == true)
        #expect(set.annotations.count == 2)
    }

    /// A new mark is always the last row, wherever its span sits.
    ///
    /// **This test asserted the opposite until 2026-09-07**, when Tom found
    /// document order non-obvious in dogfood: marking a span and watching it
    /// appear *above* the previous one, wearing a number he did not expect,
    /// reads as the panel rearranging his work.
    ///
    /// The old rationale — "the agent reads the list against a message it
    /// still holds, so presentation order disagreeing with reading order
    /// would make it hunt" — was about the agent. The list is a surface the
    /// *user* works in, and the agent has the quote on every entry, so it
    /// never has to hunt for anything.
    @Test("An accepted selection lands last, wherever its span sits")
    func insertKeepsSelectionOrder() {
        var set = existing()

        // Earlier in the message, marked second.
        #expect(set.insert(ReplyAnnotation(quote: "earlier", note: "", range: 0..<7)) == true)

        #expect(set.annotations.map(\.quote) == ["one answer is one reply", "earlier"])
        #expect(set.numbered.map(\.number) == [1, 2])
        // The payload follows the same array, so the footer cannot show one
        // order and send another — the property that made the old ordering
        // safe still holds under the new one.
        #expect(set.serialized().contains("""
        2.
        > "earlier"
        """))
    }
}
