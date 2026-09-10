import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `#cm-82` — which note an ↑/↓ step lands on.
///
/// The one piece of the step with branches: neighbour, wrap, and the cases
/// that must not move at all. Everything else in the step is focus and
/// scrolling, which only the running panel can show (the brief's human
/// scenarios).
@Suite
struct ReplyNoteStepTests {
    @Test
    func stepsToTheNeighbour() {
        #expect(ReplyNoteStep.target(from: 4, count: 9, .next) == 5)
        #expect(ReplyNoteStep.target(from: 4, count: 9, .previous) == 3)
    }

    /// Tom chose wrap-around (2026-09-10), on a fresh press.
    @Test
    func aFreshPressWrapsAtBothEnds() {
        #expect(ReplyNoteStep.target(from: 8, count: 9, .next) == 0)
        #expect(ReplyNoteStep.target(from: 0, count: 9, .previous) == 8)
    }

    /// A held key walks to the end and stops, so it cannot lap the list and
    /// land at random. Only a fresh press wraps.
    @Test
    func aHeldKeyStepsButNeverWraps() {
        #expect(ReplyNoteStep.target(from: 4, count: 9, .next, isRepeat: true) == 5)
        #expect(ReplyNoteStep.target(from: 8, count: 9, .next, isRepeat: true) == nil)
        #expect(ReplyNoteStep.target(from: 0, count: 9, .previous, isRepeat: true) == nil)
    }

    /// With one note, wrap would land on the note you are in; with none there
    /// is nowhere to go. Either way the key falls through to the text field.
    @Test
    func oneOrNoNotesNeverStep() {
        #expect(ReplyNoteStep.target(from: 0, count: 1, .next) == nil)
        #expect(ReplyNoteStep.target(from: 0, count: 1, .previous) == nil)
        #expect(ReplyNoteStep.target(from: 0, count: 0, .next) == nil)
    }

    /// A stale index — the list re-numbered under the caret — must not jump
    /// or trap.
    @Test
    func anOutOfRangeIndexNeverSteps() {
        #expect(ReplyNoteStep.target(from: 9, count: 9, .next) == nil)
        #expect(ReplyNoteStep.target(from: -1, count: 9, .next) == nil)
    }
}
