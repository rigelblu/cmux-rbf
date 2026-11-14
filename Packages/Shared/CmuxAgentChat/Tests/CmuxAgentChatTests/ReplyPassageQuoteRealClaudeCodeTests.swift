import Foundation
import Testing

@testable import CmuxAgentChat

/// `cm-136.1` Scenario 2 on **real Claude Code output** (118-column pane, 2026-11-09).
///
/// The rows are what `cmux read-screen` returned for a live Claude Code pane (`build/r1/screen.txt` for the
/// 86-column table, whose top border is its line 20; `build/r1/<shape>.screen.txt` for the rest), except the lines
/// composed for the edge tests, which are named here: `"⏺ Intro row."`,
/// `"  The table above lists four layers and where a failure shows up first."` and the 118-column `─` rule row.
///
/// Expectations: the prose, bullet, numbered, nested-bullet and code ones are transcript-derived (the agent's own
/// answer from its session transcript; markup Claude Code renders as styling, such as backticks, is in neither the
/// rows nor the expectation). The table and rule ones are screen-derived (the rows, indent removed), because a
/// transcript holds a markdown table, not the drawn box. The rest of the 29 judged passages are evidence in
/// `build/r1/`.
@Suite("ReplyPassageQuoteRealClaudeCode")
struct ReplyPassageQuoteRealClaudeCodeTests {
    private static let columns = 118

    private static let proseFromMidRow: String = [
        "Users began putting their working directory and host name into PS1 once they had several machines and",
        "  several folders to keep track of. The prompt was the only place a shell could show state, so it slowly collected",
        "  more of"
    ].joined(separator: "\n")

    private static let bulletsFromMidRow: String = [
        "from the terminal.",
        "  - Each new layer, such as escape codes, pseudo-terminals, and multiplexers, was added beside the old stream rather",
        "    than in place of it, so decades of software keep running.",
        "  - Text composes well: output can be piped into other tools, saved to files, searched, diffed, and pasted into chat,",
        "    which a graphical view of the same"
    ].joined(separator: "\n")

    private static let numberedList: String = [
        "  1. Check the TERM variable first, because programs look up escape codes by that name, and a wrong value makes a",
        "     correct terminal print garbage; set it to one the emulator really supports, then run the command again.",
        "  2. Reset the terminal with reset or stty sane when the output stays broken, since an interrupted program can leave",
        "     the terminal in raw mode or with a changed color or cursor state that the next command inherits.",
        "  3. Narrow the problem by running the same command in a fresh shell with a minimal configuration, then re-adding your",
        "     dotfiles one at a time, so the single line that causes the garbling shows up without guessing."
    ].joined(separator: "\n")

    private static let mixedNested: String = [
        "  - Start with the shell's own configuration, because a line-editing key that does nothing usually comes from a",
        "    binding set there rather than from the terminal window.",
        "    - Reload the shell in a fresh window after each edit, so you confirm the change took effect and did not just",
        "      persist in the session you already have open."
    ].joined(separator: "\n")

    private static let codeWithWrappedPrint: String = [
        "⏺ import shutil",
        "  columns, rows = shutil.get_terminal_size(fallback=(80, 24))",
        "  label = \"terminal\"",
        "  size = f\"{label}: {columns} columns by {rows} rows\"",
        "  print(size)",
        "  print(\"This string literal is deliberately long so that the printed line runs well past one hundred characters for",
        "  the check.\")",
        "  for line in range(rows):",
        "      print(\"-\" * columns if line == 0 else \"\")"
    ].joined(separator: "\n")

    private static let narrowTable: String = [
        "  ┌─────────────┬──────────────────────────┬───────────────────┬─────────────────────┐",
        "  │    Layer    │           Owns           │  Typical failure  │    Where to look    │",
        "  ├─────────────┼──────────────────────────┼───────────────────┼─────────────────────┤",
        "  │ Emulator    │ Grid and rendering       │ Wrong glyph width │ Terminal settings   │",
        "  ├─────────────┼──────────────────────────┼───────────────────┼─────────────────────┤",
        "  │ Shell       │ Line editing and history │ Keys do nothing   │ Readline bindings   │",
        "  ├─────────────┼──────────────────────────┼───────────────────┼─────────────────────┤",
        "  │ Multiplexer │ Session survival         │ Lags new codes    │ Passthrough options │",
        "  ├─────────────┼──────────────────────────┼───────────────────┼─────────────────────┤",
        "  │ Program     │ Drawing its own screen   │ Garbled output    │ TERM variable value │",
        "  └─────────────┴──────────────────────────┴───────────────────┴─────────────────────┘"
    ].joined(separator: "\n")

    private static let fullWidthTable: String = [
        "⏺ ┌─────────────┬───────────────────────────────┬───────────────────────────────┬─────────────────────────────────┐",
        "  │    Layer    │         What it owns          │        Common failure         │       Where to look first       │",
        "  ├─────────────┼───────────────────────────────┼───────────────────────────────┼─────────────────────────────────┤",
        "  │             │ Drawing the grid, glyph       │ Wide characters and emoji     │ Font and width settings in the  │",
        "  │ Emulator    │ widths, and rendering the     │ push the cursor out of line   │ emulator preferences            │",
        "  │             │ byte stream                   │                               │                                 │",
        "  ├─────────────┼───────────────────────────────┼───────────────────────────────┼─────────────────────────────────┤",
        "  │ Shell       │ Reading commands, line        │ Control-R or arrow keys do    │ Readline or line-editor key     │",
        "  │             │ editing, and history recall   │ nothing at the prompt         │ bindings in the shell config    │",
        "  ├─────────────┼───────────────────────────────┼───────────────────────────────┼─────────────────────────────────┤",
        "  │ Multiplexer │ Keeping sessions alive and    │ New escape codes never reach  │ Passthrough options and the     │",
        "  │             │ splitting panes               │ the outer terminal            │ multiplexer's terminal settings │",
        "  ├─────────────┼───────────────────────────────┼───────────────────────────────┼─────────────────────────────────┤",
        "  │             │ Drawing its own screen and    │ Output arrives as garbage,    │ The TERM value the program sees │",
        "  │ Program     │ reading its keys              │ with stray characters in the  │  at startup                     │",
        "  │             │                               │ text                          │                                 │",
        "  └─────────────┴───────────────────────────────┴───────────────────────────────┴─────────────────────────────────┘"
    ].joined(separator: "\n")

    private static let codeExpected = "import shutil\ncolumns, rows = shutil.get_terminal_size(fallback=(80, 24))\nlabel = \"terminal\"\nsize = f\"{label}: {columns} columns by {rows} rows\"\nprint(size)\nprint(\"This string literal is deliberately long so that the printed line runs well past one hundred characters for the check.\")\nfor line in range(rows):\n    print(\"-\" * columns if line == 0 else \"\")"

    private static let narrowTableExpected = "┌─────────────┬──────────────────────────┬───────────────────┬─────────────────────┐\n│    Layer    │           Owns           │  Typical failure  │    Where to look    │\n├─────────────┼──────────────────────────┼───────────────────┼─────────────────────┤\n│ Emulator    │ Grid and rendering       │ Wrong glyph width │ Terminal settings   │\n├─────────────┼──────────────────────────┼───────────────────┼─────────────────────┤\n│ Shell       │ Line editing and history │ Keys do nothing   │ Readline bindings   │\n├─────────────┼──────────────────────────┼───────────────────┼─────────────────────┤\n│ Multiplexer │ Session survival         │ Lags new codes    │ Passthrough options │\n├─────────────┼──────────────────────────┼───────────────────┼─────────────────────┤\n│ Program     │ Drawing its own screen   │ Garbled output    │ TERM variable value │\n└─────────────┴──────────────────────────┴───────────────────┴─────────────────────┘"

    private static let fullWidthTableExpected = "┌─────────────┬───────────────────────────────┬───────────────────────────────┬─────────────────────────────────┐\n│    Layer    │         What it owns          │        Common failure         │       Where to look first       │\n├─────────────┼───────────────────────────────┼───────────────────────────────┼─────────────────────────────────┤\n│             │ Drawing the grid, glyph       │ Wide characters and emoji     │ Font and width settings in the  │\n│ Emulator    │ widths, and rendering the     │ push the cursor out of line   │ emulator preferences            │\n│             │ byte stream                   │                               │                                 │\n├─────────────┼───────────────────────────────┼───────────────────────────────┼─────────────────────────────────┤\n│ Shell       │ Reading commands, line        │ Control-R or arrow keys do    │ Readline or line-editor key     │\n│             │ editing, and history recall   │ nothing at the prompt         │ bindings in the shell config    │\n├─────────────┼───────────────────────────────┼───────────────────────────────┼─────────────────────────────────┤\n│ Multiplexer │ Keeping sessions alive and    │ New escape codes never reach  │ Passthrough options and the     │\n│             │ splitting panes               │ the outer terminal            │ multiplexer's terminal settings │\n├─────────────┼───────────────────────────────┼───────────────────────────────┼─────────────────────────────────┤\n│             │ Drawing its own screen and    │ Output arrives as garbage,    │ The TERM value the program sees │\n│ Program     │ reading its keys              │ with stray characters in the  │  at startup                     │\n│             │                               │ text                          │                                 │\n└─────────────┴───────────────────────────────┴───────────────────────────────┴─────────────────────────────────┘"

    private static let blockquote: String = [
        "⏺ ▎ The terminal bell is a holdover from the teletype, where code 7 rang a real bell inside the machine to get an",
        "  ▎ operator's attention across a noisy room. Terminals kept it because it still does one useful job: it signals that",
        "  ▎ something needs a person's attention without requiring them to watch the screen. Modern emulators turn the same",
        "  ▎ byte into a visual flash, a dock bounce, or a notification, so the old signal survived by changing its shape while",
        "  ▎ keeping its purpose."
    ].joined(separator: "\n")
    private static let blockquoteExpected = "The terminal bell is a holdover from the teletype, where code 7 rang a real bell inside the machine to get an operator's attention across a noisy room. Terminals kept it because it still does one useful job: it signals that something needs a person's attention without requiring them to watch the screen. Modern emulators turn the same byte into a visual flash, a dock bounce, or a notification, so the old signal survived by changing its shape while keeping its purpose."

    private func clean(_ raw: String, from column: Int = 0) -> String {
        ReplyPassageQuote.cleanTerminalSelection(raw, wrapColumns: Self.columns, firstRowStartColumn: column)
    }

    @Test("realClaudeCode: prose that starts mid-row joins its wrapped rows")
    func realClaudeCodeProseFromMidRow() {
        #expect(clean(Self.proseFromMidRow, from: 11) == "Users began putting their working directory and host name into PS1 once they had several machines and several folders to keep track of. The prompt was the only place a shell could show state, so it slowly collected more of")
    }

    @Test("realClaudeCode: a selection that runs into bullets keeps each bullet on its own line")
    func realClaudeCodeBulletsFromMidRow() {
        #expect(clean(Self.bulletsFromMidRow, from: 12) == "from the terminal.\n- Each new layer, such as escape codes, pseudo-terminals, and multiplexers, was added beside the old stream rather than in place of it, so decades of software keep running.\n- Text composes well: output can be piped into other tools, saved to files, searched, diffed, and pasted into chat, which a graphical view of the same")
    }

    @Test("realClaudeCode: numbered items keep their breaks and join their wrapped rows")
    func realClaudeCodeNumberedList() {
        #expect(clean(Self.numberedList) == "1. Check the TERM variable first, because programs look up escape codes by that name, and a wrong value makes a correct terminal print garbage; set it to one the emulator really supports, then run the command again.\n2. Reset the terminal with reset or stty sane when the output stays broken, since an interrupted program can leave the terminal in raw mode or with a changed color or cursor state that the next command inherits.\n3. Narrow the problem by running the same command in a fresh shell with a minimal configuration, then re-adding your dotfiles one at a time, so the single line that causes the garbling shows up without guessing.")
    }

    @Test("realClaudeCode: a bullet with a nested bullet keeps the nesting")
    func realClaudeCodeNestedBullet() {
        #expect(clean(Self.mixedNested) == "- Start with the shell's own configuration, because a line-editing key that does nothing usually comes from a binding set there rather than from the terminal window.\n- Reload the shell in a fresh window after each edit, so you confirm the change took effect and did not just persist in the session you already have open.")
    }

    @Test("realClaudeCode: a code block keeps its lines and indent, and rejoins the wrapped print")
    func realClaudeCodeCodeBlockWrappedPrint() {
        #expect(clean(Self.codeWithWrappedPrint) == Self.codeExpected)
    }

    @Test("realClaudeCode: an 86-column boxed table keeps every row, border rows included")
    func realClaudeCodeNarrowTable() {
        #expect(clean(Self.narrowTable) == Self.narrowTableExpected)
    }

    @Test("realClaudeCode: a 118-column boxed table keeps every row, border rows included")
    func realClaudeCodeFullWidthTable() {
        #expect(clean(Self.fullWidthTable) == Self.fullWidthTableExpected)
    }

    @Test("realClaudeCode: a paragraph right after a full-width table stays on its own line")
    func realClaudeCodeParagraphAfterFullWidthTable() {
        let raw = Self.fullWidthTable + "\n  The table above lists four layers and where a failure shows up first."
        #expect(clean(raw) == Self.fullWidthTableExpected + "\nThe table above lists four layers and where a failure shows up first.")
    }

    /// A real full-width prose row (from the answer about the shell prompt).
    private static let fullProseRow = "  for the superuser, and that convention still holds in most shells today. The Bourne shell, written by Stephen Bourne"

    @Test("realClaudeCode: a table drawn straight under a full-width prose row stays apart from it")
    func realClaudeCodeTableDirectlyAfterAFullRow() {
        let raw = "⏺ Intro row.\n" + Self.fullProseRow + "\n" + Self.narrowTable
        let expected = "Intro row.\n" + String(Self.fullProseRow.dropFirst(2)) + "\n" + Self.narrowTableExpected
        #expect(clean(raw) == expected)
    }

    @Test("realClaudeCode: a full-width rule row (U+2500 first) is not joined onto the row above")
    func realClaudeCodeRuleRowStaysApart() {
        let rule = String(repeating: "─", count: 118)
        let raw = "⏺ Intro row.\n" + Self.fullProseRow + "\n  " + rule
        #expect(clean(raw) == "Intro row.\n" + String(Self.fullProseRow.dropFirst(2)) + "\n" + rule)
    }

    // MARK: blockquotes (Claude Code draws markdown `> ` as `▎ `, U+258E and a space)

    @Test("realClaudeCode: a wrapped blockquote loses its gutter and rejoins its rows (transcript text without the `> `)")
    func realClaudeCodeBlockquote() {
        #expect(clean(Self.blockquote) == Self.blockquoteExpected)
    }

    @Test("realClaudeCode: prose straight under a blockquote stays apart from it")
    func realClaudeCodeProseAfterQuote() {
        // Composed: the last captured quote row, made full width, then a prose row.
        let raw = Self.blockquote + "\n  Every terminal that rings a bell is still answering a question."
        #expect(clean(raw) == Self.blockquoteExpected + "\nEvery terminal that rings a bell is still answering a question.")
    }

    @Test("realClaudeCode: a quote straight under a full-width prose row stays apart from it")
    func realClaudeCodeQuoteAfterProse() {
        // Composed: a captured 118-column prose row, then the captured quote rows.
        let raw = "⏺ Intro row.\n" + Self.fullProseRow + "\n" + Self.blockquote.replacingOccurrences(of: "⏺ ", with: "  ")
        #expect(clean(raw) == "Intro row.\n" + String(Self.fullProseRow.dropFirst(2)) + "\n" + Self.blockquoteExpected)
    }

    @Test("realClaudeCode: a lone gutter row inside a quote is a blank line, and keeps its break")
    func realClaudeCodeBlankQuoteRow() {
        // Composed: two captured quote paragraphs' worth of rows with a lone `▎` between them.
        let raw = "⏺ ▎ First paragraph of the quote.\n  ▎\n  ▎ Second paragraph of the quote."
        #expect(clean(raw) == "First paragraph of the quote.\n\nSecond paragraph of the quote.")
    }

    @Test("realClaudeCode: a quote's wrap column is reduced by its gutter")
    func realClaudeCodeQuoteWrapColumnReducedByGutter() {
        // Composed: row 1 is 112 columns as drawn (marker 2 + gutter 2 + 108 of text); the next word is 7 characters,
        // so the text needs 110 + 1 + 7 = 118 against 118 - 2 = 116 once the gutter is taken off: it was wrapped.
        let words = Array(repeating: "abcdefghi", count: 10).joined(separator: " ") + " abcdefgh"
        let raw = "⏺ ▎ " + words + "\n  ▎ wrapped end"
        #expect(clean(raw) == words + " wrapped end")
    }

    @Test("realClaudeCode: a selection that starts inside a quote's first row, after the gutter, still rejoins")
    func realClaudeCodeQuoteStartedMidFirstRow() {
        let rows = Self.blockquote.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let cut = 20
        let raw = String(rows[0].dropFirst(cut)) + "\n" + rows.dropFirst().joined(separator: "\n")
        let expectedTail = String(Self.blockquoteExpected.dropFirst(cut - 4))
        #expect(clean(raw, from: cut) == expectedTail)
    }

    @Test("realClaudeCode: a quote row whose next word still fits within the pane keeps its break")
    func realClaudeCodeQuoteRowWithRoomKeepsItsBreak() {
        // Composed: row 1 is 108 columns as drawn (marker 2 + gutter 2 + 104 of text); the next word is 8 characters,
        // so 108 + 1 + 8 = 117 fits in 118: the agent ended the row there on purpose.
        let words = Array(repeating: "abcdefghi", count: 10).joined(separator: " ") + " abcd"
        let raw = "⏺ ▎ " + words + "\n  ▎ abcdefgh end"
        #expect(clean(raw) == words + "\nabcdefgh end")
    }
}
