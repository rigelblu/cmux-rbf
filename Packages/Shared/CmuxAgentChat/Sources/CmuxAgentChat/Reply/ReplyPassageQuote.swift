import Foundation

/// What reply inline (`cm-136.1`) puts in the agent's prompt for a passage
/// selected in the terminal: the quote's framing, and the cleaning of the
/// terminal's text before it is framed.
///
/// Pure and AppKit-free, beside ``ReplyAnnotationSet``, which owns the quote
/// format. The Reply panel and reply inline share one framing function
/// (`quoteBlock`) and differ in one thing: inline Reply has no width limit.
public enum ReplyPassageQuote {
    /// The glyphs an agent's program draws in front of a message or a tool
    /// result. A selection that starts at the message's first cell carries one.
    private static let markerGlyphs: Set<Character> = ["⏺", "●", "⎿"]

    /// Frames `passage` for the agent's prompt (Q10, Tom 2026-11-05): a
    /// passage with no line break is one `> "…"` line at any length, and one
    /// with line breaks is a fence of `max(3, longest backtick run inside + 1)`
    /// backticks (`quoteBlock`).
    public static func quote(_ passage: String) -> String {
        ReplyAnnotationSet.quoteBlock(passage, inlineBudget: nil)
    }

    /// Removes what the agent's program added to a terminal selection: the
    /// marker glyph, the indent, and the line breaks it added where its text
    /// wrapped. Blank lines between paragraphs and list-item breaks stay.
    ///
    /// **The rule (measured: 29 real passages and a real blockquote, fix rounds
    /// 1–4; walkthrough 1's Scenario 26 rejoined a wrap in a 45-column pane):**
    /// a row was wrapped by the agent's program when the next row's
    /// first word would not have fit on it within `wrapColumns`. That is the
    /// only evidence a wrap leaves, because the program writes a real newline
    /// where a terminal would soft-wrap (`#cm-89`, 2026-09-13).
    ///
    /// **Exceptions, rows that are never joined onto the row above (and
    /// nothing joins onto a box row):** a list item (bullet or number), a
    /// heading, a quote or fence line, a `|` table row, and a box row, one
    /// whose first character is box-drawing (U+2500–U+257F: Claude Code's
    /// boxed tables and rules).
    ///
    /// **Quotes:** Claude Code draws markdown `> ` as `▎ ` (U+258E and a
    /// space), once per level. Those gutters are stripped (`> ` is not put back:
    /// that is the markdown lookup's job), the rows of one quote are joined by
    /// the rule above with `wrapColumns` less the gutter, a lone `▎` row stays a
    /// blank line, and a quote never joins across its edge to the rows around it.
    ///
    /// - Parameters:
    ///   - wrapColumns: the width the agent wraps at: the pane's columns minus
    ///     the program's right margin. The margin is a parameter because a
    ///     build check measures it.
    ///   - firstRowStartColumn: the column of the selection's first cell. A
    ///     selection that starts mid-row arrives without the cells before it,
    ///     so its first row measures that much narrower than it was drawn.
    ///     (Added beyond the brief's signature: without it every selection
    ///     that starts mid-row keeps its first break.)
    public static func cleanTerminalSelection(
        _ raw: String,
        wrapColumns: Int,
        firstRowStartColumn: Int = 0
    ) -> String {
        // Trailing spaces are not drawn text, so they don't count toward width.
        let drawn = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { trimmingTrailingSpaces(String($0)) }
        var widths = drawn.map(\.count)
        widths[0] += max(0, firstRowStartColumn)

        var rows = drawn
        rows[0] = droppingMarker(from: rows[0])

        // The indent the program put on every continuation row.
        let sharedIndent = rows.dropFirst()
            .filter { !$0.isEmpty }
            .map(leadingSpaceCount)
            .min() ?? 0
        for index in rows.indices.dropFirst() {
            rows[index] = String(rows[index].dropFirst(min(sharedIndent, leadingSpaceCount(rows[index]))))
        }

        // Claude Code draws a markdown quote's `> ` as `▎ ` (U+258E and a space)
        // on every row, one per level. Strip it, and keep the rows of one quote
        // together as a block that never joins across its edge.
        var levels = [Int](repeating: 0, count: rows.count)
        for index in rows.indices {
            let split = splittingQuoteGutter(from: rows[index])
            levels[index] = split.level
            rows[index] = split.body
        }
        // A selection that starts after the gutter's cells (mid-way along a quote's
        // first row) arrives without its gutter: it belongs to the quote below it.
        if firstRowStartColumn > 0, levels[0] == 0, rows.count > 1, levels[1] > 0 {
            levels[0] = levels[1]
        }

        var lines = [rows[0]]
        for index in rows.indices.dropFirst() {
            let row = rows[index]
            let text = String(row.drop(while: { $0 == " " }))
            if isWrappedRow(
                text,
                after: rows[index - 1],
                previousWidth: widths[index - 1],
                sameQuote: levels[index] == levels[index - 1],
                wrapColumns: wrapColumns
            ) {
                lines[lines.count - 1] += " " + text
            } else {
                lines.append(row)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rows

    /// Whether `text` is the wrapped rest of the row above it. Both rows must be
    /// in the same quote, and neither may open a structure or be a box row. The
    /// row above plus `text`'s first word would not fit in `wrapColumns`. Widths
    /// are as drawn: gutter and indent included, so `wrapColumns` is drawn width too.
    private static func isWrappedRow(
        _ text: String,
        after previous: String,
        previousWidth: Int,
        sameQuote: Bool,
        wrapColumns: Int
    ) -> Bool {
        guard !previous.isEmpty, sameQuote, !opensStructure(text), !isBoxRow(text),
              !isBoxRow(String(previous.drop(while: { $0 == " " }))),
              let firstWord = text.split(separator: " ").first else { return false }
        return previousWidth + 1 + firstWord.count > wrapColumns
    }

    private static func trimmingTrailingSpaces(_ row: String) -> String {
        var end = row.endIndex
        while end > row.startIndex, row[row.index(before: end)] == " " { end = row.index(before: end) }
        return String(row[..<end])
    }

    private static func leadingSpaceCount(_ row: String) -> Int {
        row.prefix(while: { $0 == " " }).count
    }

    /// The first row without its marker glyph and the space after it.
    private static func droppingMarker(from row: String) -> String {
        let body = row.drop(while: { $0 == " " })
        guard let first = body.first, markerGlyphs.contains(first) else { return row }
        let rest = body.dropFirst()
        return String(rest.first == " " ? rest.dropFirst() : rest)
    }

    /// A row without its quote gutters: each leading `▎` and the one space
    /// after it. `level` is how many there were (0: not a quote row). A row
    /// that is only gutters has an empty body: a blank line inside the quote.
    private static func splittingQuoteGutter(from row: String) -> (level: Int, body: String) {
        var rest = Substring(row.drop(while: { $0 == " " }))
        var level = 0
        while rest.first == "\u{258E}" {
            level += 1
            rest = rest.dropFirst()
            if rest.first == " " { rest = rest.dropFirst() }
        }
        return level == 0 ? (0, row) : (level, String(rest))
    }

    /// Whether a row is part of a boxed table the program drew (`┌─┬─┐`,
    /// `│ … │`, `├─┼─┤`, `└─┴─┘`): its first character is a box-drawing glyph
    /// (U+2500–U+257F). Claude Code draws a table's border rows as one word
    /// as wide as the table, which the wrap rule would read as a wrapped
    /// word. A table row is never joined onto the row above, and nothing is
    /// joined onto it, so a paragraph straight after the table stays apart.
    private static func isBoxRow(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first else { return false }
        return (0x2500...0x257F).contains(first.value)
    }

    /// Whether a row starts a list item, heading, table row, quote or fence:
    /// a row the agent's program starts on purpose, never one it wrapped to.
    private static func opensStructure(_ text: String) -> Bool {
        for bullet in ["- ", "* ", "+ ", "• ", "◦ ", "▪ "] where text.hasPrefix(bullet) { return true }
        if text.hasPrefix("|") || text.hasPrefix(">") || text.hasPrefix("```") || text.hasPrefix("~~~") {
            return true
        }
        let afterHashes = text.drop(while: { $0 == "#" })
        if afterHashes.count < text.count, afterHashes.first == " " { return true }
        let digits = text.prefix(while: { $0.isASCII && $0.isNumber })
        if !digits.isEmpty {
            let rest = text.dropFirst(digits.count)
            if let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " { return true }
        }
        return false
    }
}
