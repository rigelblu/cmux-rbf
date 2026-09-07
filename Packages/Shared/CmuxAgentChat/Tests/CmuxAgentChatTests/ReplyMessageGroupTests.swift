import Foundation
import Testing

@testable import CmuxAgentChat

/// Grouping a transcript window into the replies the Reply panel navigates.
///
/// Every case here is a way the panel could show the wrong thing while
/// looking like it works: two replies fused into one, narration counted as
/// a reply, a tool-only turn you can step to and read nothing on.
@Suite("ReplyMessageGroup")
struct ReplyMessageGroupTests {
    private func agentProse(
        id: String,
        seq: Int,
        text: String,
        apiMessageID: String?,
        phase: String? = nil
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text)),
            apiMessageID: apiMessageID,
            phase: phase
        )
    }

    private func agentThought(
        id: String,
        seq: Int,
        text: String,
        apiMessageID: String?
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .thought(ChatThought(text: text)),
            apiMessageID: apiMessageID
        )
    }

    private func agentToolUse(id: String, seq: Int, apiMessageID: String?) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .toolUse(ChatToolUse(toolName: "Read", summary: "Read a file")),
            apiMessageID: apiMessageID
        )
    }

    private func userProse(id: String, seq: Int, text: String) -> ChatMessage {
        ChatMessage(
            id: id,
            seq: seq,
            role: .user,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }

    @Test("Blocks sharing an apiMessageID become one reply")
    func groupsBlocksOfOneResponse() {
        let messages = [
            agentProse(id: "line-1", seq: 1, text: "First block.", apiMessageID: "msg_A"),
            agentProse(id: "line-2", seq: 2, text: "Second block.", apiMessageID: "msg_A"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.count == 1)
        #expect(groups.first?.id == "msg_A")
        #expect(groups.first?.messages.count == 2)
        #expect(groups.first?.markdown == "First block.\n\nSecond block.")
    }

    @Test("A group takes the seq and timestamp of its first block")
    func groupTakesFirstBlockPosition() {
        let messages = [
            agentProse(id: "line-7", seq: 7, text: "First.", apiMessageID: "msg_A"),
            agentProse(id: "line-8", seq: 8, text: "Second.", apiMessageID: "msg_A"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.first?.seq == 7)
        #expect(groups.first?.timestamp == Date(timeIntervalSince1970: 7))
    }

    @Test("Two responses in one turn are one reply")
    func fusesResponsesWithinOneTurn() {
        // The API ends a response wherever it stops to call a tool. The user
        // never asked for that break and cannot see it, so two responses with
        // no prompt between them are one answer.
        let messages = [
            agentProse(id: "line-1", seq: 1, text: "Reply one.", apiMessageID: "msg_A"),
            agentProse(id: "line-2", seq: 2, text: "Reply two.", apiMessageID: "msg_B"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.count == 1)
        #expect(groups.first?.markdown == "Reply one.\n\nReply two.")
    }

    @Test("A user prompt between two responses splits them")
    func userPromptSplitsTurns() {
        // The prompt is the only turn boundary there is. A `tool_result` is
        // not one of these: `ClaudeTranscriptParser.parseUser` routes those
        // blocks to `resolveToolResult`, which emits no `ChatMessage` at all,
        // so a mid-answer tool run cannot reach here as a user message.
        let messages = [
            agentProse(id: "line-1", seq: 1, text: "First answer.", apiMessageID: "msg_A"),
            userProse(id: "line-2", seq: 2, text: "Now do the next thing."),
            agentProse(id: "line-3", seq: 3, text: "Second answer.", apiMessageID: "msg_B"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.map(\.markdown) == ["First answer.", "Second answer."])
        #expect(groups.map(\.id) == ["msg_A", "msg_B"])
    }

    @Test("One prompt with a tool call mid-answer is one reply")
    func toolCallMidAnswerStaysOneReply() {
        // The dogfood repro: this rendered as two panel messages (`10/11`,
        // `11/11`) while the terminal showed one continuous answer with
        // `Read 1 file` in the middle.
        let messages = [
            userProse(id: "line-1", seq: 1, text: "What does this file do?"),
            agentProse(id: "line-2", seq: 2, text: "Let me check.", apiMessageID: "msg_A"),
            agentToolUse(id: "line-3", seq: 3, apiMessageID: "msg_A"),
            agentProse(id: "line-4", seq: 4, text: "It parses transcripts.", apiMessageID: "msg_B"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.count == 1)
        #expect(groups.first?.markdown == "Let me check.\n\nIt parses transcripts.")
    }

    @Test("A turn whose prompt is off the window still forms a reply")
    func partialHeadTurnStillGroups() {
        // The window is bounded and nothing aligns it to turn boundaries, so
        // the oldest loaded turn routinely starts mid-answer. Dropping it
        // would lose the oldest reply the panel can show.
        let messages = [
            agentProse(id: "line-8", seq: 8, text: "…the rest of it.", apiMessageID: "msg_A"),
            userProse(id: "line-9", seq: 9, text: "Thanks."),
            agentProse(id: "line-10", seq: 10, text: "Anytime.", apiMessageID: "msg_B"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.map(\.markdown) == ["…the rest of it.", "Anytime."])
    }

    @Test("A user prompt is never a reply")
    func excludesUserMessages() {
        let messages = [
            userProse(id: "line-1", seq: 1, text: "Please do the thing."),
            agentProse(id: "line-2", seq: 2, text: "Done.", apiMessageID: "msg_A"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.count == 1)
        #expect(groups.first?.markdown == "Done.")
    }

    @Test("Messages naming no response id are separated by the prompt, not the id")
    func ungroupableMessagesSplitOnThePrompt() {
        // Codex's older rollouts name no id. Under turn grouping that costs
        // nothing: the prompt separates the replies, so a missing id no
        // longer has to. Two `nil`s inside one turn are one answer.
        let messages = [
            agentProse(id: "line-1", seq: 1, text: "Reply one.", apiMessageID: nil),
            userProse(id: "line-2", seq: 2, text: "Next, please."),
            agentProse(id: "line-3", seq: 3, text: "Reply two.", apiMessageID: nil),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.map(\.id) == ["line-1", "line-3"])
        #expect(groups.map(\.markdown) == ["Reply one.", "Reply two."])
    }

    @Test("Codex commentary is not a reply")
    func excludesCodexCommentary() {
        // Codex writes each narration entry as its own line with its own id.
        // Kept, they would put a dozen entries into one turn's counter and
        // make stepping back walk through narration instead of replies.
        let messages = [
            agentProse(
                id: "line-1", seq: 1, text: "Looking at the file…",
                apiMessageID: "msg_A", phase: "commentary"
            ),
            agentProse(
                id: "line-2", seq: 2, text: "Here is the answer.",
                apiMessageID: "msg_B", phase: "final_answer"
            ),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.count == 1)
        #expect(groups.first?.id == "msg_B")
        #expect(groups.first?.markdown == "Here is the answer.")
    }

    @Test("A turn that only called a tool is not a reply")
    func dropsGroupsWithoutProse() {
        // Two turns: the first answered with a tool run and no words, so
        // stepping to it would show an empty panel.
        let messages = [
            userProse(id: "line-1", seq: 1, text: "Run it."),
            agentToolUse(id: "line-2", seq: 2, apiMessageID: "msg_A"),
            userProse(id: "line-3", seq: 3, text: "What did it say?"),
            agentProse(id: "line-4", seq: 4, text: "Here is what I found.", apiMessageID: "msg_B"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.map(\.id) == ["msg_B"])
    }

    @Test("A tool run inside a reply stays part of it")
    func keepsToolUseAlongsideProse() {
        let messages = [
            agentProse(id: "line-1", seq: 1, text: "Let me check.", apiMessageID: "msg_A"),
            agentToolUse(id: "line-2", seq: 2, apiMessageID: "msg_A"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.count == 1)
        #expect(groups.first?.messages.count == 2)
        #expect(groups.first?.markdown == "Let me check.")
    }

    @Test("No agent messages means no replies")
    func emptyWindowYieldsNoGroups() {
        #expect(ReplyMessageGroup.groups(from: []).isEmpty)
        #expect(ReplyMessageGroup.groups(from: [userProse(id: "l1", seq: 1, text: "hi")]).isEmpty)
    }

    // MARK: - Rendering reasoning

    @Test("A reply with no reasoning renders exactly its own text")
    func renderedMarkdownWithoutThinkingIsJustTheReply() {
        let groups = ReplyMessageGroup.groups(from: [
            agentProse(id: "m1", seq: 1, text: "Just the answer.", apiMessageID: "msg_A"),
        ])
        let group = try! #require(groups.first)
        #expect(group.renderedMarkdown(thinkingLabel: "Show thinking") == "Just the answer.")
        #expect(group.thinking.isEmpty)
    }

    @Test("Reasoning renders behind a disclosure, above the reply")
    func renderedMarkdownPutsThinkingBehindADisclosure() {
        let groups = ReplyMessageGroup.groups(from: [
            agentThought(id: "m1", seq: 1, text: "Weighing two options.", apiMessageID: "msg_A"),
            agentProse(id: "m2", seq: 2, text: "I picked the second.", apiMessageID: "msg_A"),
        ])
        let group = try! #require(groups.first)
        let rendered = group.renderedMarkdown(thinkingLabel: "Show thinking")

        #expect(rendered.contains("<details class=\"cmux-reply-thinking\">"))
        #expect(rendered.contains("<summary>Show thinking</summary>"))
        #expect(rendered.contains("Weighing two options."))
        #expect(rendered.contains("I picked the second."))
        // Blank lines around the body are what make CommonMark parse the
        // reasoning as markdown instead of literal text inside raw HTML.
        #expect(rendered.contains("</summary>\n\nWeighing two options.\n\n</details>"))
        // The disclosure comes first, matching transcript order.
        let detailsAt = try! #require(rendered.range(of: "<details"))
        let replyAt = try! #require(rendered.range(of: "I picked the second."))
        #expect(detailsAt.lowerBound < replyAt.lowerBound)
    }

    @Test("Reasoning stays out of the text a note can quote")
    func thinkingIsNotPartOfTheQuotableReply() {
        // The design settled that thinking is shown but not annotatable, so
        // `markdown` — the text `cm-69.2` quotes spans from — must not carry
        // it. Only the rendered document does.
        let groups = ReplyMessageGroup.groups(from: [
            agentThought(id: "m1", seq: 1, text: "Private reasoning.", apiMessageID: "msg_A"),
            agentProse(id: "m2", seq: 2, text: "The reply.", apiMessageID: "msg_A"),
        ])
        let group = try! #require(groups.first)
        #expect(group.markdown == "The reply.")
        #expect(!group.markdown.contains("Private reasoning."))
    }

    @Test("Several reasoning blocks in one reply share one disclosure")
    func multipleThoughtsShareOneDisclosure() {
        let groups = ReplyMessageGroup.groups(from: [
            agentThought(id: "m1", seq: 1, text: "First thought.", apiMessageID: "msg_A"),
            agentThought(id: "m2", seq: 2, text: "Second thought.", apiMessageID: "msg_A"),
            agentProse(id: "m3", seq: 3, text: "Answer.", apiMessageID: "msg_A"),
        ])
        let group = try! #require(groups.first)
        let rendered = group.renderedMarkdown(thinkingLabel: "Show thinking")
        #expect(group.thinking == ["First thought.", "Second thought."])
        #expect(rendered.components(separatedBy: "<details").count == 2)
        #expect(rendered.contains("First thought.\n\nSecond thought."))
    }

    @Test("The disclosure label is escaped, not injected")
    func thinkingLabelIsEscaped() {
        let groups = ReplyMessageGroup.groups(from: [
            agentThought(id: "m1", seq: 1, text: "Reasoning.", apiMessageID: "msg_A"),
            agentProse(id: "m2", seq: 2, text: "Reply.", apiMessageID: "msg_A"),
        ])
        let group = try! #require(groups.first)
        let rendered = group.renderedMarkdown(thinkingLabel: "<script>x</script>")
        #expect(rendered.contains("&lt;script&gt;x&lt;/script&gt;"))
        #expect(!rendered.contains("<script>"))
    }

    // MARK: - Paging a window that starts mid-answer

    /// Neither handle on a group survives paging, and the second one is the
    /// surprise: `seq` reads like a transcript position but is only ever
    /// *the current first message's* position, so it moves with `id`.
    ///
    /// Observed 2026-09-07 while fixing `cm-69.2b`'s draft key, which had
    /// been about to move from `id` to this field on the belief that it
    /// "never moves": `(partial.seq -> 3) == (completed.seq -> 1)`.
    /// Anything pinning to a reply must anchor on a **message** `seq` and
    /// resolve it through membership, the way ``ReplyPanelModel`` does.
    @Test("Paging the prompt in moves both the group's id and its seq")
    func pagingMovesGroupIdentityAndPosition() {
        // A window that starts mid-answer: the turn's tail, then its prompt.
        let windowed = ReplyMessageGroup.groups(from: [
            agentProse(id: "m3", seq: 3, text: "Third part.", apiMessageID: "msg_A"),
            agentProse(id: "m4", seq: 4, text: "Fourth part.", apiMessageID: "msg_A"),
            userProse(id: "m5", seq: 5, text: "Next prompt."),
            agentProse(id: "m6", seq: 6, text: "Later reply.", apiMessageID: "msg_B"),
        ])
        let partial = try! #require(windowed.first)

        // Paging older history in completes that same turn.
        let paged = ReplyMessageGroup.groups(from: [
            userProse(id: "m0", seq: 0, text: "The prompt."),
            agentProse(id: "m1", seq: 1, text: "First part.", apiMessageID: "msg_Z"),
            agentProse(id: "m2", seq: 2, text: "Second part.", apiMessageID: "msg_Z"),
            agentProse(id: "m3", seq: 3, text: "Third part.", apiMessageID: "msg_A"),
            agentProse(id: "m4", seq: 4, text: "Fourth part.", apiMessageID: "msg_A"),
            userProse(id: "m5", seq: 5, text: "Next prompt."),
            agentProse(id: "m6", seq: 6, text: "Later reply.", apiMessageID: "msg_B"),
        ])
        let completed = try! #require(paged.first)

        // It is the same reply: the tail the window could see is still in it.
        #expect(completed.messages.contains { $0.seq == 3 })
        #expect(completed.messages.contains { $0.seq == 4 })

        // And neither handle on it survived.
        #expect(partial.id != completed.id)
        #expect(partial.seq == 3)
        #expect(completed.seq == 1)
    }
}
