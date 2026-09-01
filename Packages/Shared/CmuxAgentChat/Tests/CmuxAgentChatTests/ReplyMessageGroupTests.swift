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
}
