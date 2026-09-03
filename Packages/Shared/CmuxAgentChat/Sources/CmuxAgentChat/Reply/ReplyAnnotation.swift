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

    public init(id: UUID = UUID(), quote: String, note: String) {
        self.id = id
        self.quote = quote
        self.note = note
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
    /// Anchored instructions, in **document order** — the order the spans
    /// appear in the message, never the order they were written.
    ///
    /// The agent reads the list top to bottom against a message it still
    /// holds; presentation order that disagreed with reading order would
    /// make it hunt.
    public var annotations: [ReplyAnnotation]

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

    /// Whether there is anything worth sending.
    ///
    /// This is what the delivery buttons gate on. Without it an empty draft
    /// would paste an empty string into the composer, which reads as cmux
    /// having malfunctioned rather than as the user not having written
    /// anything yet.
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
    /// An ordered list of `> "span"` + instruction, then an optional `---`
    /// block of whole-message notes. **No header line** — the quotes are the
    /// frame, and a header ("Feedback on your last message:") only told the
    /// agent what the quotes already showed.
    ///
    /// The message itself is never re-quoted wholesale. Plannotator's
    /// rewrite-from-scratch failure came from bare comments with no anchor;
    /// re-quoting the whole message causes the same rewrite from the other
    /// direction. The agent already holds the message.
    public func serialized() -> String {
        var blocks: [String] = []

        for (offset, annotation) in annotations.filter(\.isDeliverable).enumerated() {
            let marker = "\(offset + 1). "
            // Continuation lines indent to the marker's own width, so the
            // note stays inside its list item at any index. At 1-9 that is
            // the three spaces the wire format fixture pins; at 10+ it is
            // four, which is what keeps the list from breaking rather than a
            // second format.
            let indent = String(repeating: " ", count: marker.count)
            blocks.append(marker + quoteBlock(annotation.quote, indent: indent))
            blocks.append(
                annotation.note
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { indent + $0 }
                    .joined(separator: "\n")
            )
        }

        let notes = trimmedMessageNotes
        if !notes.isEmpty {
            if !blocks.isEmpty { blocks.append("---") }
            blocks.append(contentsOf: notes)
        }

        return blocks.joined(separator: "\n")
    }

    /// Renders one quote as a blockquote, keeping a multi-line span inside it.
    ///
    /// A cross-block selection carries a newline, and an unprefixed second
    /// line would fall out of the blockquote and read to the agent as
    /// instruction rather than as quoted text — the one confusion this whole
    /// format exists to prevent.
    private func quoteBlock(_ quote: String, indent: String) -> String {
        let lines = quote
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
        return lines.enumerated().map { offset, line in
            let prefix = offset == 0 ? "> \"" : "\(indent)> "
            let suffix = offset == lines.count - 1 ? "\"" : ""
            return prefix + line + suffix
        }.joined(separator: "\n")
    }
}
