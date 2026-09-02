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

    @Test("Two responses stay two replies")
    func doesNotFuseSeparateResponses() {
        let messages = [
            agentProse(id: "line-1", seq: 1, text: "Reply one.", apiMessageID: "msg_A"),
            agentProse(id: "line-2", seq: 2, text: "Reply two.", apiMessageID: "msg_B"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.map(\.id) == ["msg_A", "msg_B"])
        #expect(groups.map(\.markdown) == ["Reply one.", "Reply two."])
    }

    @Test("A user turn between two blocks of one response does not split it")
    func userTurnBetweenBlocksDoesNotSplit() {
        // A `tool_result` arrives as a user line mid-response. Filtering to
        // agent messages must happen before the run scan, or the response
        // splits in two and the counter gains a reply that was never sent.
        let messages = [
            agentProse(id: "line-1", seq: 1, text: "Before the tool.", apiMessageID: "msg_A"),
            userProse(id: "line-2", seq: 2, text: "tool result"),
            agentProse(id: "line-3", seq: 3, text: "After the tool.", apiMessageID: "msg_A"),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.count == 1)
        #expect(groups.first?.markdown == "Before the tool.\n\nAfter the tool.")
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

    @Test("Messages naming no response id each stand alone")
    func ungroupableMessagesNeverFuse() {
        // Codex's older rollouts name no id, and there one line is one whole
        // reply. Treating two `nil`s as the same group would fuse two
        // separate replies into one unquotable blob.
        let messages = [
            agentProse(id: "line-1", seq: 1, text: "Reply one.", apiMessageID: nil),
            agentProse(id: "line-2", seq: 2, text: "Reply two.", apiMessageID: nil),
        ]

        let groups = ReplyMessageGroup.groups(from: messages)

        #expect(groups.map(\.id) == ["line-1", "line-2"])
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
        let messages = [
            agentToolUse(id: "line-1", seq: 1, apiMessageID: "msg_A"),
            agentProse(id: "line-2", seq: 2, text: "Here is what I found.", apiMessageID: "msg_B"),
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
}
