import Foundation
import Testing

@testable import CmuxAgentChat

/// Unsent marks surviving the transcript moving under them.
///
/// The failure these guard against is silent and unrecoverable: the notes
/// leave the footer, nothing says so, and there is no copy of them anywhere.
@Suite("ReplyDrafts")
struct ReplyDraftsTests {
    private func agentProse(seq: Int, text: String, apiMessageID: String?) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text)),
            apiMessageID: apiMessageID
        )
    }

    private func userProse(seq: Int, text: String) -> ChatMessage {
        ChatMessage(
            id: "m\(seq)",
            seq: seq,
            role: .user,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text))
        )
    }

    /// The turn's tail, as a window that started mid-answer sees it.
    private var partialWindow: [ChatMessage] {
        [
            agentProse(seq: 3, text: "Third part.", apiMessageID: "msg_A"),
            agentProse(seq: 4, text: "Fourth part.", apiMessageID: "msg_A"),
            userProse(seq: 5, text: "Next prompt."),
            agentProse(seq: 6, text: "Later reply.", apiMessageID: "msg_B"),
        ]
    }

    /// The same transcript once paging has pulled the prompt in.
    private var pagedWindow: [ChatMessage] {
        [
            userProse(seq: 0, text: "The prompt."),
            agentProse(seq: 1, text: "First part.", apiMessageID: "msg_Z"),
            agentProse(seq: 2, text: "Second part.", apiMessageID: "msg_Z"),
        ] + partialWindow
    }

    /// Distinct ranges, because ``ReplyAnnotationSet/insert(_:)`` refuses a
    /// mark overlapping one already there.
    private func note(_ text: String, at range: Range<Int> = 0..<11) -> ReplyAnnotation {
        ReplyAnnotation(quote: "Third part.", note: text, range: range)
    }

    /// The repro from the pick-up note, driven end to end.
    @Test("Notes written on a mid-answer reply survive paging its prompt in")
    func draftSurvivesPagingOlderHistory() {
        let partial = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)

        var drafts = ReplyDrafts()
        drafts.update(for: partial) { $0.insert(note("Say why here.")) }
        #expect(drafts.draft(for: partial).annotations.count == 1)

        // Press `◄` far enough back that the panel pages in older history.
        let completed = try! #require(ReplyMessageGroup.groups(from: pagedWindow).first)

        // The group was renamed and repositioned by that paging — the whole
        // reason this type does not key on either.
        #expect(completed.id != partial.id)
        #expect(completed.seq != partial.seq)

        // The notes are still there, on the reply they were written on.
        #expect(drafts.draft(for: completed).annotations.count == 1)
        #expect(drafts.draft(for: completed).annotations.first?.note == "Say why here.")
    }

    @Test("Editing after a paging event updates the draft rather than starting a second")
    func editAfterPagingKeepsOneDraft() {
        let partial = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)
        var drafts = ReplyDrafts()
        drafts.update(for: partial) { $0.insert(note("First.")) }

        let completed = try! #require(ReplyMessageGroup.groups(from: pagedWindow).first)
        drafts.update(for: completed) { $0.insert(note("Second.", at: 20..<30)) }

        #expect(drafts.draft(for: completed).annotations.count == 2)
        // And the reply is still one draft, not two halves under two keys.
        #expect(drafts.draft(for: partial).annotations.count == 2)
    }

    @Test("A draft belongs to its own reply and no other")
    func draftsAreScopedToOneReply() {
        let groups = ReplyMessageGroup.groups(from: pagedWindow)
        #expect(groups.count == 2)
        let older = groups[0]
        let newer = groups[1]

        var drafts = ReplyDrafts()
        drafts.update(for: older) { $0.insert(note("On the older one.")) }

        #expect(drafts.draft(for: older).annotations.count == 1)
        #expect(drafts.draft(for: newer).annotations.isEmpty)
    }

    @Test("Clearing a delivered reply leaves every other reply's notes alone")
    func clearingIsScopedToOneReply() {
        let groups = ReplyMessageGroup.groups(from: pagedWindow)
        let older = groups[0]
        let newer = groups[1]

        var drafts = ReplyDrafts()
        drafts.update(for: older) { $0.insert(note("Older.")) }
        drafts.update(for: newer) { $0.insert(note("Newer.")) }

        drafts.clear(for: newer)

        #expect(drafts.draft(for: newer).annotations.isEmpty)
        #expect(drafts.draft(for: older).annotations.count == 1)
    }

    /// Clearing resolves through the same anchor a write used, so a delivery
    /// after a paging event does not leave the notes behind on screen.
    @Test("Clearing after paging finds the draft it is meant to drop")
    func clearAfterPagingDropsTheDraft() {
        let partial = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)
        var drafts = ReplyDrafts()
        drafts.update(for: partial) { $0.insert(note("Send this.")) }

        let completed = try! #require(ReplyMessageGroup.groups(from: pagedWindow).first)
        drafts.clear(for: completed)

        #expect(drafts.draft(for: completed).annotations.isEmpty)
        #expect(drafts.draft(for: partial).annotations.isEmpty)
    }

    @Test("A reply nobody marked up reads as empty rather than as somebody else's draft")
    func unmarkedReplyIsEmpty() {
        let groups = ReplyMessageGroup.groups(from: pagedWindow)
        var drafts = ReplyDrafts()
        drafts.update(for: groups[0]) { $0.insert(note("Only here.")) }

        #expect(drafts.draft(for: groups[1]).isEmpty)
        #expect(!drafts.draft(for: groups[0]).isEmpty)
    }

    // MARK: - The two other ways the window moves

    /// A reply grows at its *back* while the agent is still writing it, and
    /// marks can be made on it before it settles. Re-deriving the anchor on
    /// each edit would file the second note under the newer last message and
    /// strand it.
    @Test("Notes written while a reply is still being written stay in one draft")
    func draftSurvivesTheReplyStillGrowing() {
        let streaming = try! #require(ReplyMessageGroup.groups(from: [
            userProse(seq: 0, text: "The prompt."),
            agentProse(seq: 1, text: "First part.", apiMessageID: "msg_Z"),
        ]).first)

        var drafts = ReplyDrafts()
        drafts.update(for: streaming) { $0.insert(note("On the first part.")) }

        // The agent writes more of the same reply.
        let grown = try! #require(ReplyMessageGroup.groups(from: [
            userProse(seq: 0, text: "The prompt."),
            agentProse(seq: 1, text: "First part.", apiMessageID: "msg_Z"),
            agentProse(seq: 2, text: "Second part.", apiMessageID: "msg_Z"),
        ]).first)
        drafts.update(for: grown) { $0.insert(note("On the second.", at: 20..<30)) }

        // One draft holding both, not two halves under two keys.
        #expect(drafts.draft(for: grown).annotations.count == 2)

        // And delivering it clears both.
        drafts.clear(for: grown)
        #expect(drafts.draft(for: grown).isEmpty)
    }

    /// The window is bounded, so its oldest messages are dropped. A reply
    /// straddling that boundary is still readable — and its notes have to
    /// still be there, which is why the anchor is taken from the end of a
    /// reply rather than its head.
    @Test("Notes survive the window trimming the front off their reply")
    func draftSurvivesTrimmingTheReplysHead() {
        let whole = try! #require(ReplyMessageGroup.groups(from: pagedWindow).first)
        var drafts = ReplyDrafts()
        drafts.update(for: whole) { $0.insert(note("Written before the trim.")) }

        // The window slides: the prompt and the reply's first blocks go.
        let trimmed = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)
        #expect(!trimmed.messages.contains { $0.seq == 1 })

        #expect(drafts.draft(for: trimmed).annotations.count == 1)
        #expect(drafts.draft(for: trimmed).annotations.first?.note == "Written before the trim.")
    }
}
