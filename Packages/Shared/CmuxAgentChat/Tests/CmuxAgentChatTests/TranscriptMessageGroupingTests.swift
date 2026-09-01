import Foundation
import Testing

@testable import CmuxAgentChat

/// `ChatMessage.id` is per *content block*, which is enough to render a
/// transcript and not enough to say "these came from one model response".
/// These cover the two fields that close that gap: ``ChatMessage/apiMessageID``
/// (which response) and ``ChatMessage/phase`` (which part of the turn).
///
/// Fixture shapes mirror the real transcripts, verified against
/// `~/.claude/projects/<cwd>/<session>.jsonl` and 40 rollouts under
/// `~/.codex/sessions/2026/`.
@Suite("Transcript message grouping")
struct TranscriptMessageGroupingTests {

    // MARK: - Claude

    private let claude = ClaudeTranscriptParser()

    private func claudeAssistantLine(
        uuid: String,
        messageID: String?,
        blocks: [[String: Any]],
        timestamp: String = "2026-06-12T05:08:20.730Z"
    ) -> String {
        var message: [String: Any] = [
            "model": "claude-fable-5", "type": "message",
            "role": "assistant", "content": blocks, "stop_reason": "end_turn",
        ]
        if let messageID { message["id"] = messageID }
        let data = try! JSONSerialization.data(withJSONObject: [
            "parentUuid": "u-1", "isSidechain": false, "type": "assistant",
            "message": message,
            "uuid": uuid, "timestamp": timestamp, "sessionId": "s-1",
        ])
        return String(decoding: data, as: UTF8.self)
    }

    @Test("One Claude response spanning several blocks groups under one apiMessageID")
    func claudeGroupsBlocksOfOneResponse() {
        // The load-bearing case: Claude writes one JSONL line per content
        // block, so thinking and text arrive as separate messages whose only
        // shared fact is the response id.
        let line = claudeAssistantLine(
            uuid: "a-1",
            messageID: "msg_01XSwgMFhsK2QtUAzAAbMC2N",
            blocks: [
                ["type": "thinking", "thinking": "Weighing two options."],
                ["type": "text", "text": "Here is the answer."],
            ]
        )
        let messages = claude.parse(lines: [line], startingSeq: 0).messages

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.apiMessageID == "msg_01XSwgMFhsK2QtUAzAAbMC2N" })
        // Grouping must add something `id` cannot: the per-block ids differ.
        #expect(Set(messages.map(\.id)).count == 2)
    }

    @Test("Two Claude responses do not fuse into one group")
    func claudeSeparatesDistinctResponses() {
        let first = claudeAssistantLine(
            uuid: "a-1", messageID: "msg_A",
            blocks: [["type": "text", "text": "First response."]]
        )
        let second = claudeAssistantLine(
            uuid: "a-2", messageID: "msg_B",
            blocks: [["type": "text", "text": "Second response."]]
        )
        let messages = claude.parse(lines: [first, second], startingSeq: 0).messages

        #expect(messages.count == 2)
        #expect(messages[0].apiMessageID == "msg_A")
        #expect(messages[1].apiMessageID == "msg_B")
    }

    @Test("A Claude line naming no response id yields nil, never a fabricated group")
    func claudeApiMessageIDIsNilWhenAbsent() {
        // `nil` must mean "ungroupable". Falling back to the line uuid would
        // make every block its own group and read as if grouping worked.
        let line = claudeAssistantLine(
            uuid: "a-1", messageID: nil,
            blocks: [["type": "text", "text": "No id on this one."]]
        )
        let messages = claude.parse(lines: [line], startingSeq: 0).messages

        #expect(messages.count == 1)
        #expect(messages[0].apiMessageID == nil)
    }

    @Test("Claude tags no turn phase")
    func claudeSetsNoPhase() {
        let line = claudeAssistantLine(
            uuid: "a-1", messageID: "msg_A",
            blocks: [["type": "text", "text": "Answer."]]
        )
        let messages = claude.parse(lines: [line], startingSeq: 0).messages

        #expect(messages.count == 1)
        #expect(messages[0].phase == nil)
    }

    // MARK: - Codex

    private let codex = CodexTranscriptParser()

    private func codexMessageLine(
        role: String = "assistant",
        text: String,
        id: String? = nil,
        phase: String? = nil
    ) -> String {
        var payload: [String: Any] = [
            "type": "message", "role": role,
            "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]],
        ]
        if let id { payload["id"] = id }
        if let phase { payload["phase"] = phase }
        let data = try! JSONSerialization.data(withJSONObject: [
            "timestamp": "2026-06-11T21:38:05.381Z", "type": "response_item", "payload": payload,
        ])
        return String(decoding: data, as: UTF8.self)
    }

    @Test("Codex carries its response id through to apiMessageID")
    func codexPopulatesApiMessageID() {
        let line = codexMessageLine(text: "The answer.", id: "item_042", phase: "final_answer")
        let messages = codex.parse(lines: [line], startingSeq: 0).messages

        #expect(messages.count == 1)
        #expect(messages[0].apiMessageID == "item_042")
    }

    @Test("Codex distinguishes final_answer from commentary")
    func codexReportsPhase() {
        // Commentary is Codex's running narration while it works — the
        // structural twin of Claude's thinking. A consumer that cannot tell
        // the two apart walks backwards through narration.
        let answer = codexMessageLine(text: "Done.", id: "item_1", phase: "final_answer")
        let narration = codexMessageLine(text: "Now checking the tests.", id: "item_2", phase: "commentary")
        let messages = codex.parse(lines: [answer, narration], startingSeq: 0).messages

        #expect(messages.count == 2)
        #expect(messages[0].phase == "final_answer")
        #expect(messages[1].phase == "commentary")
    }

    @Test("An older Codex rollout with neither field parses with both nil")
    func codexToleratesMissingFields() {
        // Rollouts from 2026-05 carry no `id` and no `phase`; they must still
        // parse rather than being dropped or crashing.
        let line = codexMessageLine(text: "Older format.")
        let messages = codex.parse(lines: [line], startingSeq: 0).messages

        #expect(messages.count == 1)
        #expect(messages[0].apiMessageID == nil)
        #expect(messages[0].phase == nil)
    }

    @Test("A Codex user prompt takes neither field")
    func codexUserMessageUnaffected() {
        let line = codexMessageLine(role: "user", text: "Do the thing.", id: "item_9")
        let messages = codex.parse(lines: [line], startingSeq: 0).messages

        #expect(messages.count == 1)
        #expect(messages[0].role == .user)
        #expect(messages[0].apiMessageID == nil)
    }

    // MARK: - The shared model

    @Test("Both fields survive a wire round trip")
    func fieldsRoundTripThroughCoding() throws {
        // The Mac produces these and the phone decodes them; a field that
        // does not survive encoding is a field the phone never sees.
        let original = ChatMessage(
            id: "b-1", seq: 4, role: .agent,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            kind: .prose(ChatProse(text: "Hello.")),
            apiMessageID: "msg_A", phase: "final_answer"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        #expect(decoded.apiMessageID == "msg_A")
        #expect(decoded.phase == "final_answer")
        #expect(decoded == original)
    }

    @Test("A payload written before these fields existed still decodes")
    func legacyPayloadDecodesWithNilFields() throws {
        // The decoder fails open by design; an older Mac talking to a newer
        // phone must not sink a whole history page over one absent field.
        let json = """
        {"id":"b-1","seq":4,"role":"agent","timestamp":0,
         "kind":{"case":"prose","prose":{"text":"Hello."}}}
        """
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: Data(json.utf8))

        #expect(decoded.apiMessageID == nil)
        #expect(decoded.phase == nil)
    }
}
