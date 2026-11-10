import Foundation
import Testing

@testable import CmuxAgentChat

/// `cm-136.1` Scenario 2: the cleaner removes what the agent's program added
/// to a terminal selection (marker glyph, indent, line breaks at wraps) and
/// nothing else.
///
/// **These are synthetic.** `wrapped(_:columns:)` plays Claude Code's wrap:
/// greedy, a `⏺ ` on the first row, two spaces of indent on the rest. The
/// real fixtures (Scenario 2's 20 selections) come from the probe build and
/// are added beside these; until then the rule is proven against its own
/// model of the agent, which is exactly as good as the model.
@Suite("ReplyPassageQuoteClean")
struct ReplyPassageQuoteCleanTests {
    /// The rows Claude Code draws for `text` at `columns`: `⏺ ` then two
    /// spaces of indent, wrapping greedily at word boundaries.
    private func wrapped(_ text: String, columns: Int, marker: String = "⏺ ") -> String {
        var rows: [String] = []
        var current = marker
        var atRowStart = true
        for word in text.split(separator: " ") {
            let candidate = atRowStart ? current + word : current + " " + word
            if candidate.count > columns, !atRowStart {
                rows.append(current)
                current = "  " + word
            } else {
                current = candidate
            }
            atRowStart = false
        }
        rows.append(current)
        return rows.joined(separator: "\n")
    }

    private static let sentence =
        "Transport is secondary; a Mac-side relay is the main path. A documented, origin-checked open tab carries the session when the relay is down."

    // MARK: marker glyphs

    @Test("A leading ⏺ and its space are dropped", arguments: ["⏺", "●", "⎿"])
    func markerGlyphIsDropped(marker: String) {
        #expect(ReplyPassageQuote.cleanTerminalSelection("\(marker) Hello there", wrapColumns: 80) == "Hello there")
    }

    @Test("A glyph that is not at the start of the selection stays")
    func midTextGlyphStays() {
        #expect(ReplyPassageQuote.cleanTerminalSelection("see ⏺ here", wrapColumns: 80) == "see ⏺ here")
    }

    // MARK: indent

    @Test("The indent shared by the continuation rows is removed")
    func sharedIndentIsRemoved() {
        let raw = "⏺ first line\n  second line\n  third line"
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 80) == "first line\nsecond line\nthird line")
    }

    @Test("Nesting deeper than the shared indent is kept")
    func nestingBeyondTheSharedIndentIsKept() {
        let raw = "⏺ list:\n  - one\n    - nested\n  - two"
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 80) == "list:\n- one\n  - nested\n- two")
    }

    // MARK: wraps

    @Test("Rows the agent's program wrapped are joined with one space", arguments: [30, 40, 60, 80])
    func wrappedParagraphIsJoined(columns: Int) {
        let raw = wrapped(Self.sentence, columns: columns)
        #expect(raw.contains("\n") == (columns < Self.sentence.count))
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: columns) == Self.sentence)
    }

    @Test("Two short rows that would have fit on one stay two rows")
    func shortRowsAreNotJoined() {
        #expect(ReplyPassageQuote.cleanTerminalSelection("⏺ ok\n  fine", wrapColumns: 80) == "ok\nfine")
    }

    @Test("A next word that fits exactly is not a wrap")
    func exactFitIsNotAWrap() {
        // `⏺ aaa bbb` is 9 wide; ` cc` brings it to exactly 12, so the program had room and chose to break.
        #expect(ReplyPassageQuote.cleanTerminalSelection("⏺ aaa bbb\n  cc", wrapColumns: 12) == "aaa bbb\ncc")
        #expect(ReplyPassageQuote.cleanTerminalSelection("⏺ aaa bbb\n  cc", wrapColumns: 11) == "aaa bbb cc")
    }

    @Test("The margin is a parameter: the same rows join at the agent's width and not at a wider one")
    func wrapColumnsDecidesTheJoin() {
        // Claude Code wrapped at 38 of a 40-column pane (margin 2).
        let raw = wrapped(Self.sentence, columns: 38)
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 38) == Self.sentence)
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 120) != Self.sentence)
    }

    @Test("A row that runs to the pane's last column is a wrap (measured: Claude Code's margin is 0)")
    func fullWidthRowIsAWrap() {
        // Probe 2026-11-05: in a 99-column pane the longest answer row was 99 wide, indent included.
        let row = "⏺ " + String(repeating: "a", count: 97)
        #expect(row.count == 99)
        #expect(ReplyPassageQuote.cleanTerminalSelection(row + "\n  next", wrapColumns: 99)
            == String(repeating: "a", count: 97) + " next")
        let shortRow = "⏺ " + String(repeating: "a", count: 90)
        #expect(ReplyPassageQuote.cleanTerminalSelection(shortRow + "\n  next", wrapColumns: 99)
            == String(repeating: "a", count: 90) + "\nnext")
    }

    @Test("A selection that starts mid-row measures the first row from its start column")
    func firstRowStartColumnCountsTowardTheRowWidth() {
        // Drawn: `⏺ Transport is secondary; a Mac-side relay` / `  is the main path.`
        // Selected from `secondary;` on: the first row arrives without the 15 columns before it.
        let raw = "secondary; a Mac-side relay\n  is the main path."
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 44, firstRowStartColumn: 15)
            == "secondary; a Mac-side relay is the main path.")
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 44, firstRowStartColumn: 0)
            == "secondary; a Mac-side relay\nis the main path.")
    }

    // MARK: breaks that stay

    @Test("A blank line between paragraphs stays a blank line")
    func blankLineStays() {
        let raw = wrapped("First paragraph that is long enough to wrap onto a second row.", columns: 30)
            + "\n\n  Second paragraph."
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 30)
            == "First paragraph that is long enough to wrap onto a second row.\n\nSecond paragraph.")
    }

    @Test("A word longer than the pane never pulls a paragraph up over a blank line")
    func blankRowIsNeverJoinedOnto() {
        #expect(ReplyPassageQuote.cleanTerminalSelection("⏺ aaaa\n\n  bbbbbbbb", wrapColumns: 5) == "aaaa\n\nbbbbbbbb")
    }

    @Test("List items keep their line breaks, bullets and numbers alike", arguments: [
        "- ", "* ", "+ ", "• ", "1. ", "12) ",
    ])
    func listItemRowsAreNotJoined(bullet: String) {
        let raw = "⏺ steps:\n  \(bullet)one\n  \(bullet)two"
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 8) == "steps:\n\(bullet)one\n\(bullet)two")
    }

    @Test("Heading, table and fence rows keep their line breaks", arguments: ["# Title", "| a | b |", "```swift", "> quoted"])
    func structuralRowsAreNotJoined(row: String) {
        let raw = "⏺ intro words\n  \(row)"
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 14) == "intro words\n\(row)")
    }

    // MARK: edges

    @Test("A single row is only trimmed")
    func singleRow() {
        #expect(ReplyPassageQuote.cleanTerminalSelection("  just words  ", wrapColumns: 80) == "just words")
    }

    @Test("Trailing spaces on a row do not count toward its width")
    func trailingSpacesDoNotCount() {
        // Drawn width 13 (16 with the spaces); `dd` fits within 17 only if they don't count.
        let raw = "⏺ aaa bbb ccc   \n  dd"
        #expect(ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: 17) == "aaa bbb ccc\ndd")
    }

    @Test("Empty and whitespace-only input come back empty")
    func emptyInput() {
        #expect(ReplyPassageQuote.cleanTerminalSelection("", wrapColumns: 80) == "")
        #expect(ReplyPassageQuote.cleanTerminalSelection(" \n  \n", wrapColumns: 80) == "")
    }
}
