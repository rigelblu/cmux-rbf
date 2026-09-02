import Foundation

/// One agent **turn**: everything the agent wrote in answer to one prompt.
///
/// A transcript writes one line per *content block*, and the API ends a
/// response wherever the agent stopped to call a tool — so one answer
/// arrives as several ``ChatMessage`` values spanning several
/// ``ChatMessage/apiMessageID`` values. Neither break is one the user asked
/// for or can see: the terminal shows one continuous answer with the tool
/// run in the middle.
///
/// It is the unit the Reply panel navigates: `◄ n/N ►` steps one answer,
/// never one block and never one API response. Grouping by response id
/// instead showed a single answer as two panel messages, and left
/// `cm-69.2` unable to anchor a span running from one paragraph to the
/// next.
public struct ReplyMessageGroup: Identifiable, Sendable, Equatable {
    /// Identity for the group among the currently loaded window.
    ///
    /// The first constituent's ``ChatMessage/apiMessageID`` when the
    /// transcript names one; otherwise that message's own id.
    ///
    /// **Unique, but not stable across windows.** A turn is delimited by the
    /// prompt in front of it, so a window that starts mid-answer names the
    /// turn after whichever response it could see — and paging the prompt in
    /// renames it. Nothing may pin a reading position to this;
    /// ``ReplyPanelModel`` anchors by message `seq`, which never moves.
    public let id: String

    /// Transcript position of the group's first message.
    ///
    /// Groups sort by this, and it is the cursor for paging older history.
    public let seq: Int

    /// When the group's first message was written.
    public let timestamp: Date

    /// Every constituent message, in transcript order.
    ///
    /// Kept whole rather than reduced to text: the tool runs and thinking
    /// blocks in a reply are part of it, and a later slice renders them.
    public let messages: [ChatMessage]

    /// Creates a group.
    ///
    /// - Parameters:
    ///   - id: Shared response identity, or the lone message's own id.
    ///   - seq: Transcript position of the first constituent.
    ///   - timestamp: When the first constituent was written.
    ///   - messages: Constituents in transcript order.
    public init(id: String, seq: Int, timestamp: Date, messages: [ChatMessage]) {
        self.id = id
        self.seq = seq
        self.timestamp = timestamp
        self.messages = messages
    }

    /// The reply's prose, ready to hand to a markdown renderer.
    ///
    /// Text blocks only, in transcript order, joined as separate
    /// paragraphs — two content blocks were never one paragraph, and
    /// joining them without a break would run the last sentence of one
    /// into the first word of the next.
    public var markdown: String {
        messages
            .compactMap { message in
                guard case let .prose(prose) = message.kind else { return nil }
                return prose.text
            }
            .joined(separator: "\n\n")
    }

    /// The reply's reasoning, in transcript order.
    public var thinking: [String] {
        messages.compactMap { message in
            guard case let .thought(thought) = message.kind else { return nil }
            let text = thought.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// The document the panel renders: the reasoning behind a disclosure,
    /// then the reply.
    ///
    /// Separate from `markdown` on purpose. `markdown` is the reply's own
    /// text and only that — it is what a note quotes, and the design settled
    /// that thinking is shown but *not annotatable*. Folding the disclosure
    /// into `markdown` would put reasoning inside quoted spans.
    ///
    /// Emitted as raw HTML with blank lines around the body, which is what
    /// makes CommonMark parse the reasoning inside as markdown rather than
    /// literal text. `details` and `summary` both survive the viewer's
    /// sanitizer, which blocks by list and names neither.
    ///
    /// - Parameter thinkingLabel: Localized summary text. Passed in because
    ///   this package has no string catalog of its own.
    /// - Returns: Markdown, ready for the viewer.
    public func renderedMarkdown(thinkingLabel: String) -> String {
        let thinking = thinking
        guard !thinking.isEmpty else { return markdown }
        let body = thinking.joined(separator: "\n\n")
        let disclosure = """
        <details class="cmux-reply-thinking">
        <summary>\(Self.escapedForHTML(thinkingLabel))</summary>

        \(body)

        </details>
        """
        let reply = markdown
        return reply.isEmpty ? disclosure : disclosure + "\n\n" + reply
    }

    /// Escapes text bound for an HTML element's content.
    ///
    /// Only the summary needs it: the reasoning body is deliberately parsed
    /// as markdown, and the viewer sanitizes the result.
    private static func escapedForHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

extension ReplyMessageGroup {
    /// Codex's tag for the narration it writes while working, as opposed to
    /// the reply it finishes with.
    ///
    /// The structural twin of Claude's thinking blocks: interesting, but not
    /// the message. Claude does not tag its lines, so this never matches
    /// there.
    static let commentaryPhase = "commentary"

    /// Groups a transcript window into the replies the Reply panel can
    /// navigate.
    ///
    /// Four rules, each of which changes what the user sees:
    ///
    /// - **The user's prompt is the only boundary.** Everything the agent
    ///   writes between two prompts is one reply, however many API responses
    ///   it took. A `tool_result` is *not* a boundary and cannot reach here
    ///   as one: `ClaudeTranscriptParser.parseUser` routes those blocks to
    ///   `resolveToolResult`, which emits no ``ChatMessage``.
    /// - **The prompt itself is not part of any reply.** It ends the run and
    ///   is dropped; a `.system` line is neither and is skipped.
    /// - **Codex `commentary` is dropped.** Codex writes each narration
    ///   entry as its own line with its own id, so keeping them would put a
    ///   dozen entries into one turn's counter and make `◄` walk through
    ///   narration. Claude's equivalent — a thinking block — rides inside
    ///   its reply's group and is dropped by the prose rule below instead.
    /// - **A group needs prose to exist.** A reply that only called a tool
    ///   has nothing to read and nothing to quote, so stepping to it would
    ///   show an empty panel.
    ///
    /// A window that starts mid-answer — the common case, since the window is
    /// bounded and nothing aligns it to turn boundaries — still yields that
    /// partial turn as a group, because it is a real reply and dropping it
    /// would lose the oldest one the panel can show. What it does *not* yield
    /// is a stable id for it: see ``ReplyPanelModel``, which is why that type
    /// pins its reading position by message `seq` rather than by group id.
    ///
    /// - Parameter messages: A transcript window in ascending `seq` order.
    /// - Returns: Navigable groups, oldest first.
    public static func groups(from messages: [ChatMessage]) -> [ReplyMessageGroup] {
        var groups: [ReplyMessageGroup] = []
        var run: [ChatMessage] = []

        func closeRun() {
            guard let first = run.first else { return }
            let hasProse = run.contains { message in
                if case .prose = message.kind { return true }
                return false
            }
            if hasProse {
                groups.append(
                    ReplyMessageGroup(
                        id: first.apiMessageID ?? first.id,
                        seq: first.seq,
                        timestamp: first.timestamp,
                        messages: run
                    )
                )
            }
            run = []
        }

        for message in messages {
            switch message.role {
            case .user:
                closeRun()
            case .agent:
                guard message.phase != commentaryPhase else { continue }
                run.append(message)
            case .system:
                continue
            }
        }
        closeRun()

        return groups
    }
}
