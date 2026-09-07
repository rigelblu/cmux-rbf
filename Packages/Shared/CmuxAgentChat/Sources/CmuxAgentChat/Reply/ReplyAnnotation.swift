import Foundation

/// One anchored instruction: a span the user selected, and what they want
/// done to it.
///
/// The quote is the **rendered** text of the selection, verbatim — what the
/// user actually saw, not the markdown behind it. That is settled and
/// load-bearing: the agent is told `bold`, never `**bold**`, and changing it
/// later retrains every agent that learned the shape.
///
/// No context words are ever added around the span. If a quote is ambiguous
/// on its own, the answer is for the user to select more, not for cmux to
/// widen it on their behalf — a widened quote is one the user never read.
public struct ReplyAnnotation: Identifiable, Sendable, Equatable {
    /// Identity within one message's annotation set.
    ///
    /// Local to the draft and never serialized: the agent reads position in
    /// the list, not ids.
    public let id: UUID

    /// The selection's rendered text, exactly as it appeared on screen.
    ///
    /// May contain newlines. A selection running from the tail of one
    /// paragraph into the head of the next is **one** annotation — the case
    /// `Range.surroundContents()` throws on — and its quote is the joined
    /// rendered text with the block break preserved.
    public let quote: String

    /// What the user wants done to that span.
    public var note: String

    /// Where the span sits in the rendered message, as character offsets
    /// into its text content.
    ///
    /// This is the DOM Range flattened to the two facts anything outside the
    /// page needs: **selection order** (marks are numbered as they are made,
    /// the agent reads the list against a message it still holds) and
    /// **overlap** (a phrase already inside an annotation cannot start a
    /// second one). Keeping it here rather than page-side is what lets both
    /// rules be a function call in the package instead of behaviour only a
    /// running WebView can show.
    ///
    /// Half-open on purpose: `Range.overlaps` is then exactly the rule the
    /// design states — *shared characters, not adjacency* — so a selection
    /// starting where another ends is allowed with no special case.
    public let range: Range<Int>

    public init(id: UUID = UUID(), quote: String, note: String, range: Range<Int>) {
        self.id = id
        self.quote = quote
        self.note = note
        self.range = range
    }

    /// Whether this entry says anything an agent could act on.
    ///
    /// A highlight with no instruction is a user mid-thought, not a request:
    /// `> "span"` alone tells the agent a span matters and nothing about
    /// what to do with it. Such entries are kept in the draft — the
    /// highlight stays on screen — and dropped at serialization.
    public var isDeliverable: Bool {
        !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Everything the user marked up on one message, ready to become a prompt.
///
/// Held whole rather than as a bare `[ReplyAnnotation]` so the trailing
/// whole-message block has somewhere to live from the start. `cm-69.2a`
/// only produces one span note, but a set that could not carry the list or
/// the trailing block would have to be reshaped for `cm-69.2b`, and every
/// call site with it.
public struct ReplyAnnotationSet: Sendable, Equatable {
    /// Anchored instructions, in **selection order** — the order the user
    /// made them, never where the spans sit in the message.
    ///
    /// **Reversed 2026-09-07 (Tom): document order was non-obvious.** Marking
    /// a span and watching it appear *above* the one marked before it,
    /// wearing a number you did not expect, reads as the panel rearranging
    /// your work. Selection order means a new mark is always the last row,
    /// which is where you are already looking.
    ///
    /// **The cost, accepted:** the numerals in the message no longer read
    /// 1, 2, 3 top to bottom. Scanning the reply they appear in whatever
    /// order the spans were marked. What it buys back is that the *list* is a
    /// history of what you did, which is the surface you actually work in.
    ///
    /// **What does not change, and is why this is safe:** the footer, the
    /// message markers and the payload all derive from this one array, so
    /// they cannot disagree. Paste order is still list order.
    ///
    /// Read-only from outside: order is an invariant of the set, not a
    /// convention its callers agree to keep. As a rule in a view it would be
    /// one edit away from being undone; as a property of the type, an
    /// out-of-order set is not reachable.
    public private(set) var annotations: [ReplyAnnotation]

    /// Notes about the message as a whole, carried under a `---` rule.
    ///
    /// Not a verdict. A whole-message *verdict* was cut for good — the agent
    /// is idle rather than blocked, so an approval has nobody to unblock —
    /// but a note that simply is not about one span still needs a home.
    public var messageNotes: [String]

    public init(annotations: [ReplyAnnotation] = [], messageNotes: [String] = []) {
        self.annotations = annotations
        self.messageNotes = messageNotes
    }

    /// Adds a marked span, refusing one that overlaps a mark already there.
    ///
    /// **Overlaps are refused at selection time, never merged or widened.**
    /// Two washes stacked over one phrase cannot be read as two marks, so
    /// allowing it would produce a highlight that lies about how many notes
    /// it carries. It also follows the rule the type already states: an
    /// ambiguous quote is fixed by the user selecting more, never by cmux
    /// widening on their behalf — so the annotation holding a phrase keeps
    /// it.
    ///
    /// - Returns: whether the mark was taken. `false` is the refusal the
    ///   selection handler reports; nothing in the set changes.
    @discardableResult
    public mutating func insert(_ annotation: ReplyAnnotation) -> Bool {
        guard !annotations.contains(where: { $0.range.overlaps(annotation.range) }) else {
            return false
        }
        annotations.append(annotation)
        return true
    }

    /// Writes the note on one mark, leaving its span and its place alone.
    ///
    /// The only way in from outside, because `annotations` is read-only: a
    /// caller that could assign the array could also reorder it, and
    /// selection order is what every number on screen is derived from.
    public mutating func updateNote(id: UUID, note: String) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].note = note
    }

    /// Drops one mark and its note, and nothing else.
    ///
    /// **This is the condition that makes *no undo* defensible.** What is
    /// destroyed is a sentence typed seconds ago about a phrase still on
    /// screen; if removal could disturb a neighbour, that stops being true
    /// and the no-undo decision stops holding. So: no cascade, no
    /// re-anchoring, no clearing of the whole-message block. Renumbering
    /// renames positions and deletes nothing.
    public mutating func remove(id: UUID) {
        annotations.removeAll { $0.id == id }
    }

    /// The marks with the numbers they carry — **one derivation for the
    /// message markers and the footer rows both.**
    ///
    /// The number is a **position in this array**, not an identity: nothing
    /// persists a number, so there is no second place for the markers and
    /// the rows to disagree within one snapshot. Removing a mark renumbers
    /// the rest, which renames positions and deletes nothing.
    ///
    /// Every mark is numbered, including one with no note yet: the number
    /// appears the moment the **mark** exists, not when text is typed into
    /// it, so it is on screen and in the field together from the first
    /// keystroke. Serialization carries the empty ones too, so the number in
    /// the footer is the number the agent reads — see ``serialized()``.
    public var numbered: [NumberedAnnotation] {
        annotations.enumerated().map { NumberedAnnotation(number: $0.offset + 1, annotation: $0.element) }
    }

    /// The longest quote that still takes a one-line `> "…"` blockquote.
    /// Anything longer takes a fence.
    ///
    /// **The trigger is width, not newlines.** A 300-character single
    /// paragraph has no line break in it and wraps anyway, and a wrapped
    /// continuation inherits none of its line's leading marks — so the `> `
    /// vanishes and the quoted text reads to the agent as instruction. That
    /// is the failure this whole format was rewritten to prevent.
    ///
    /// **Where the number comes from.** The preview renders monospace at the
    /// panel's own width, and the panel's floor is 276pt
    /// (`RightSidebarWidthSettings.minimumWidth`) less a 10pt gutter each
    /// side — about 40 monospace characters at 256pt, measured on the
    /// 2026-09-01 render pass. The quote line spends 4 of them on its own
    /// framing (`> "` and the closing `"`), leaving 36 for the span.
    ///
    /// **Why the floor and not the live width:** the format is a fixed
    /// contract sent to an agent, so it cannot depend on how wide the panel
    /// happens to be. Sizing to the narrowest the panel can get makes the
    /// rule hold at every width above it.
    ///
    /// **Which way to be wrong:** a fence where a blockquote would have fit
    /// costs two lines. A blockquote where a fence was needed reproduces the
    /// defect above. So this errs low on purpose.
    public static let inlineQuoteCharacterBudget = 36

    /// Whether there is nothing at all — no mark, no note.
    ///
    /// **This is what `Paste` gates on, and it is a lower bar than
    /// ``isDeliverable`` on purpose.** Paste puts text in the composer, where
    /// the user finishes it; a marked span with no note is worth pasting
    /// precisely because the quote is the part that is tedious to retype and
    /// the instruction is the part you were about to type anyway (Tom,
    /// dogfood 2026-09-06: *"I still don't see a reason to disable paste any
    /// time — the user might want to edit/enter the text in the agent
    /// terminal"*).
    ///
    /// The only state Paste cannot serve is this one: nothing marked, so
    /// there is nothing to put anywhere.
    public var isEmpty: Bool {
        !annotations.contains { !$0.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && trimmedMessageNotes.isEmpty
    }

    /// Whether there is anything worth **sending** — an instruction, not just
    /// a span.
    ///
    /// `Paste & Send` alone gates on this. It has no composer step, so a bare
    /// `> "span"` reaches the agent as a span with nothing asked of it, which
    /// is the one thing this format exists to prevent. Paste keeps the same
    /// payload editable, so it does not need the guard.
    public var isDeliverable: Bool {
        annotations.contains(where: \.isDeliverable) || !trimmedMessageNotes.isEmpty
    }

    private var trimmedMessageNotes: [String] {
        messageNotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The prompt the agent receives.
    ///
    /// An ordered list of anchored instructions, then an optional `---`
    /// block of whole-message notes. **No header line** — the quotes are the
    /// frame, and a header ("Feedback on your last message:") only told the
    /// agent what the quotes already showed.
    ///
    /// **Structure runs vertically, never horizontally.** The marker owns
    /// its own line, the note takes no hanging indent, and entries are
    /// separated by a blank line. Every boundary in the format is a line
    /// break rather than a leading character, and that is the whole point:
    /// the preview wraps at the panel's width, and a wrapped continuation
    /// inherits none of its line's leading marks. The retired shape carried
    /// a `> ` on every continuation and an indent to the marker's width;
    /// both vanished on a wrap, and the quoted line then read to the agent
    /// as instruction — the single confusion this format exists to prevent.
    ///
    /// The message itself is never re-quoted wholesale. Plannotator's
    /// rewrite-from-scratch failure came from bare comments with no anchor;
    /// re-quoting the whole message causes the same rewrite from the other
    /// direction. The agent already holds the message.
    public func serialized() -> String {
        var entries: [String] = []

        // **Every marked span, numbered as the footer numbers it.**
        //
        // Dropping the note-less ones renumbered what was left, so a footer
        // showing `2.` pasted as `1.` — the manifest's one job is to say what
        // Paste will send, and it was lying whenever any note was blank. The
        // old `ReplyAnnotationSetTests` even asserted the mismatch as
        // intended behaviour.
        //
        // A note-less entry contributes its quote and stops there, which is a
        // complete thought: *this span, and I will tell you what about it.*
        // `Paste` is the only route to that state, and it lands in the
        // composer where the sentence gets finished.
        for entry in numbered where !entry.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let note = entry.note.trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(
                (["\(entry.number).", quoteBlock(entry.quote)] + (note.isEmpty ? [] : [note]))
                    .joined(separator: "\n")
            )
        }

        let notes = trimmedMessageNotes
        if !notes.isEmpty {
            let block = notes.joined(separator: "\n")
            // The rule separates the whole-message block from the anchored
            // list. With no list there is nothing to separate it from.
            entries.append(entries.isEmpty ? block : "---\n" + block)
        }

        return entries.joined(separator: "\n\n")
    }

    /// Frames one quote so no line of it can be mistaken for instruction.
    ///
    /// A quote that fits one line takes `> "…"`, which reads as a quotation
    /// and costs one line. Anything longer takes a fence: it carries no
    /// per-line mark at all, so there is nothing a wrap can strip, and it
    /// survives spans containing headings, lists and fences of their own.
    private func quoteBlock(_ quote: String) -> String {
        let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("\n"), trimmed.count <= Self.inlineQuoteCharacterBudget {
            return "> \"\(trimmed)\""
        }
        // Per CommonMark a fence must be longer than any backtick run inside
        // it. Without this a span containing its own fence closes ours early
        // and the rest of the prompt falls out of the quote.
        let fence = String(
            repeating: "`",
            count: max(3, Self.longestBacktickRun(in: trimmed) + 1)
        )
        return "\(fence)\n\(trimmed)\n\(fence)"
    }

    private static func longestBacktickRun(in text: String) -> Int {
        var longest = 0
        var current = 0
        for character in text {
            current = character == "`" ? current + 1 : 0
            longest = max(longest, current)
        }
        return longest
    }
}

/// One mark paired with the number it renders, in the message and in the
/// footer alike.
///
/// A pair rather than a stored field: the number belongs to the *snapshot*,
/// not to the annotation, and an annotation carrying its own number is the
/// bug this shape exists to make unreachable.
public struct NumberedAnnotation: Identifiable, Sendable, Equatable {
    /// Position in selection order, 1-based — what the marker prints and what
    /// the footer row prints.
    public let number: Int

    public let annotation: ReplyAnnotation

    public var id: UUID { annotation.id }
    public var quote: String { annotation.quote }
    public var note: String { annotation.note }
    public var range: Range<Int> { annotation.range }
    public var isDeliverable: Bool { annotation.isDeliverable }
}

