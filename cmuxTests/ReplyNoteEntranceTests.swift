import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `#cm-83.1` — which note Tab opens when the keyboard is in the reply body.
///
/// The entrance and `#cm-82`'s step are different mechanisms and disagree in
/// exactly the places that matter: the step refuses a single note (`count > 1`)
/// where the entrance must open it, and the step always moves where the
/// entrance sometimes stays. Everything else in the entrance is focus, caret
/// placement and scrolling, which only the running panel can show.
@Suite
struct ReplyNoteEntranceTests {
    /// The plain case: Tab takes the first note, ⇧Tab the last.
    @Test
    func tabTakesTheFirstAndShiftTabTheLast() {
        #expect(ReplyNoteEntrance.target(count: 3, editingIndex: nil, backwards: false) == 0)
        #expect(ReplyNoteEntrance.target(count: 3, editingIndex: nil, backwards: true) == 2)
    }

    /// With one highlight both directions open it. `#cm-82`'s step refuses
    /// this case (`count > 1`); the entrance must not inherit that refusal,
    /// because the single note is exactly what has no keyboard route today.
    @Test
    func oneHighlightIsReachableFromBothDirections() {
        #expect(ReplyNoteEntrance.target(count: 1, editingIndex: nil, backwards: false) == 0)
        #expect(ReplyNoteEntrance.target(count: 1, editingIndex: nil, backwards: true) == 0)
    }

    /// Nothing to enter, so the key is not consumed and AppKit keeps its
    /// normal focus move. The Quality constraint this guards is "never trap
    /// the keyboard".
    @Test
    func zeroHighlightsEntersNothing() {
        #expect(ReplyNoteEntrance.target(count: 0, editingIndex: nil, backwards: false) == nil)
        #expect(ReplyNoteEntrance.target(count: 0, editingIndex: nil, backwards: true) == nil)
    }

    /// The third focus state: a note is open but the keyboard is in the body,
    /// reached by clicking unmarked reply text. Tab returns to *that* note
    /// rather than jumping to the first — the `cm-78.1` shape, where refusing
    /// instead of targeting ships a key that does nothing with a note visibly
    /// open.
    @Test
    func anOpenNoteIsRejoinedRatherThanJumpedPast() {
        #expect(ReplyNoteEntrance.target(count: 5, editingIndex: 3, backwards: false) == 3)
        #expect(ReplyNoteEntrance.target(count: 5, editingIndex: 3, backwards: true) == 3)
    }

    /// A stale index — the list re-numbered under an open note — falls back to
    /// the plain entrance rather than opening nothing or crashing.
    @Test
    func aStaleOpenIndexFallsBackToThePlainEntrance() {
        #expect(ReplyNoteEntrance.target(count: 2, editingIndex: 7, backwards: false) == 0)
        #expect(ReplyNoteEntrance.target(count: 2, editingIndex: -1, backwards: true) == 1)
    }
}
