import Foundation
import Testing

@testable import CmuxAgentChat

/// Unsent marks surviving the transcript moving under them.
///
/// The failure these guard against is silent and unrecoverable: the notes
/// leave the footer, nothing says so, and there is no copy of them anywhere.
@Suite("ReplyDrafts")
struct ReplyDraftsTests {
    /// The bound session, for every test that is not about two of them.
    private static let session = "session-one"
    private static let scope = ReplyDrafts.Scope(session: session, generation: 0)

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
        drafts.update(for: partial, in: Self.scope) { $0.insert(note("Say why here.")) }
        #expect(drafts.draft(for: partial, in: Self.scope).annotations.count == 1)

        // Press `◄` far enough back that the panel pages in older history.
        let completed = try! #require(ReplyMessageGroup.groups(from: pagedWindow).first)

        // The group was renamed and repositioned by that paging — the whole
        // reason this type does not key on either.
        #expect(completed.id != partial.id)
        #expect(completed.seq != partial.seq)

        // The notes are still there, on the reply they were written on.
        #expect(drafts.draft(for: completed, in: Self.scope).annotations.count == 1)
        #expect(drafts.draft(for: completed, in: Self.scope).annotations.first?.note == "Say why here.")
    }

    @Test("Editing after a paging event updates the draft rather than starting a second")
    func editAfterPagingKeepsOneDraft() {
        let partial = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)
        var drafts = ReplyDrafts()
        drafts.update(for: partial, in: Self.scope) { $0.insert(note("First.")) }

        let completed = try! #require(ReplyMessageGroup.groups(from: pagedWindow).first)
        drafts.update(for: completed, in: Self.scope) { $0.insert(note("Second.", at: 20..<30)) }

        #expect(drafts.draft(for: completed, in: Self.scope).annotations.count == 2)
        // And the reply is still one draft, not two halves under two keys.
        #expect(drafts.draft(for: partial, in: Self.scope).annotations.count == 2)
    }

    @Test("A draft belongs to its own reply and no other")
    func draftsAreScopedToOneReply() {
        let groups = ReplyMessageGroup.groups(from: pagedWindow)
        #expect(groups.count == 2)
        let older = groups[0]
        let newer = groups[1]

        var drafts = ReplyDrafts()
        drafts.update(for: older, in: Self.scope) { $0.insert(note("On the older one.")) }

        #expect(drafts.draft(for: older, in: Self.scope).annotations.count == 1)
        #expect(drafts.draft(for: newer, in: Self.scope).annotations.isEmpty)
    }

    @Test("Clearing a delivered reply leaves every other reply's notes alone")
    func clearingIsScopedToOneReply() {
        let groups = ReplyMessageGroup.groups(from: pagedWindow)
        let older = groups[0]
        let newer = groups[1]

        var drafts = ReplyDrafts()
        drafts.update(for: older, in: Self.scope) { $0.insert(note("Older.")) }
        drafts.update(for: newer, in: Self.scope) { $0.insert(note("Newer.")) }

        drafts.clear(for: newer, in: Self.scope)

        #expect(drafts.draft(for: newer, in: Self.scope).annotations.isEmpty)
        #expect(drafts.draft(for: older, in: Self.scope).annotations.count == 1)
    }

    /// Clearing resolves through the same anchor a write used, so a delivery
    /// after a paging event does not leave the notes behind on screen.
    @Test("Clearing after paging finds the draft it is meant to drop")
    func clearAfterPagingDropsTheDraft() {
        let partial = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)
        var drafts = ReplyDrafts()
        drafts.update(for: partial, in: Self.scope) { $0.insert(note("Send this.")) }

        let completed = try! #require(ReplyMessageGroup.groups(from: pagedWindow).first)
        drafts.clear(for: completed, in: Self.scope)

        #expect(drafts.draft(for: completed, in: Self.scope).annotations.isEmpty)
        #expect(drafts.draft(for: partial, in: Self.scope).annotations.isEmpty)
    }

    @Test("A reply nobody marked up reads as empty rather than as somebody else's draft")
    func unmarkedReplyIsEmpty() {
        let groups = ReplyMessageGroup.groups(from: pagedWindow)
        var drafts = ReplyDrafts()
        drafts.update(for: groups[0], in: Self.scope) { $0.insert(note("Only here.")) }

        #expect(drafts.draft(for: groups[1], in: Self.scope).isEmpty)
        #expect(!drafts.draft(for: groups[0], in: Self.scope).isEmpty)
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
        drafts.update(for: streaming, in: Self.scope) { $0.insert(note("On the first part.")) }

        // The agent writes more of the same reply.
        let grown = try! #require(ReplyMessageGroup.groups(from: [
            userProse(seq: 0, text: "The prompt."),
            agentProse(seq: 1, text: "First part.", apiMessageID: "msg_Z"),
            agentProse(seq: 2, text: "Second part.", apiMessageID: "msg_Z"),
        ]).first)
        drafts.update(for: grown, in: Self.scope) { $0.insert(note("On the second.", at: 20..<30)) }

        // One draft holding both, not two halves under two keys.
        #expect(drafts.draft(for: grown, in: Self.scope).annotations.count == 2)

        // And delivering it clears both.
        drafts.clear(for: grown, in: Self.scope)
        #expect(drafts.draft(for: grown, in: Self.scope).isEmpty)
    }

    /// The window is bounded, so its oldest messages are dropped. A reply
    /// straddling that boundary is still readable — and its notes have to
    /// still be there, which is why the anchor is taken from the end of a
    /// reply rather than its head.
    @Test("Notes survive the window trimming the front off their reply")
    func draftSurvivesTrimmingTheReplysHead() {
        let whole = try! #require(ReplyMessageGroup.groups(from: pagedWindow).first)
        var drafts = ReplyDrafts()
        drafts.update(for: whole, in: Self.scope) { $0.insert(note("Written before the trim.")) }

        // The window slides: the prompt and the reply's first blocks go.
        let trimmed = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)
        #expect(!trimmed.messages.contains { $0.seq == 1 })

        #expect(drafts.draft(for: trimmed, in: Self.scope).annotations.count == 1)
        #expect(drafts.draft(for: trimmed, in: Self.scope).annotations.first?.note == "Written before the trim.")
    }

    // MARK: - Two sessions, one pane

    /// A `seq` is a transcript **line index**, so every session has one.
    /// One `ReplyDrafts` lives for the whole window, held by `ReplyPanelStore`,
    /// and `refresh()` never resets it — it short-circuits on an unchanged
    /// session and otherwise re-binds the store without touching the drafts.
    /// So two transcripts with a message at the same line share a draft.
    @Test("A draft on one session's reply does not show on another session's")
    func draftsAreScopedToTheirSession() {
        let sessionA = try! #require(ReplyMessageGroup.groups(from: [
            userProse(seq: 39, text: "Prompt in session A."),
            agentProse(seq: 40, text: "Answer in session A.", apiMessageID: "msg_A"),
        ]).first)
        let sessionB = try! #require(ReplyMessageGroup.groups(from: [
            userProse(seq: 39, text: "Prompt in session B."),
            agentProse(seq: 40, text: "Answer in session B.", apiMessageID: "msg_B"),
        ]).first)

        var drafts = ReplyDrafts()
        drafts.update(for: sessionA, in: .init(session: "session-A", generation: 0)) { $0.insert(note("Meant for session A.")) }

        #expect(drafts.draft(for: sessionB, in: .init(session: "session-B", generation: 0)).isEmpty)
        // And session A still has its own — scoping the key must not drop the
        // draft, only stop it leaking. A note written before a session change
        // is still what the user wanted to say (Tom, 2026-09-07).
        #expect(drafts.draft(for: sessionA, in: .init(session: "session-A", generation: 0)).annotations.count == 1)
    }

    // MARK: - The transcript being rewritten under the drafts

    /// A compaction or `--resume` replaces the file. `ReplyPanelStore` handles
    /// it by clearing `messages` and calling `ReplyPanelModel.reset()`, which
    /// drops that model's own anchors and says why: *"Keeping the pin … would
    /// point them at whatever reply happens to land in the same position."*
    /// The session id does not change, and `seq` starts over — so a draft
    /// anchored at line 40 lands on whoever now holds line 40.
    ///
    /// The draft is not *dropped* — Tom's rule is that a note written before a
    /// rewrite is still what the user wanted to say. It simply must stop
    /// matching a stranger.
    @Test("A draft does not reattach to whatever reply lands on its line after a rewrite")
    func draftDoesNotFollowALineNumberAcrossARewrite() {
        let before = try! #require(ReplyMessageGroup.groups(from: [
            userProse(seq: 39, text: "Prompt before the rewrite."),
            agentProse(seq: 40, text: "Answer before the rewrite.", apiMessageID: "msg_before"),
        ]).first)
        let after = try! #require(ReplyMessageGroup.groups(from: [
            userProse(seq: 39, text: "A different prompt, same line."),
            agentProse(seq: 40, text: "A different answer, same line.", apiMessageID: "msg_after"),
        ]).first)

        var drafts = ReplyDrafts()
        drafts.update(for: before, in: .init(session: Self.session, generation: 0)) {
            $0.insert(note("Written before the compaction."))
        }

        // Same session, new transcript.
        #expect(drafts.draft(for: after, in: .init(session: Self.session, generation: 1)).isEmpty)
    }

    // MARK: - Text typed into the paste preview (`#cm-90`)

    /// A `‹` step closes the preview, and the view that held the typed text
    /// is rebuilt by a sidebar mode switch — so the text lives here, beside
    /// the marks it was written over, or it is lost with no warning.
    @Test("Typed preview text reads back on its reply and survives paging its prompt in")
    func typedPreviewReadsBackOnItsReply() {
        let partial = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)
        let paged = try! #require(ReplyMessageGroup.groups(from: pagedWindow).first)
        #expect(paged.id != partial.id)

        var drafts = ReplyDrafts()
        drafts.update(for: partial, in: Self.scope) { $0.insert(note("Say why here.")) }
        drafts.setTypedPreview("edited wire text", for: partial, in: Self.scope)

        #expect(drafts.typedPreview(for: partial, in: Self.scope) == "edited wire text")
        // Same anchor rule as the marks: paging renames the group, not the reply.
        #expect(drafts.typedPreview(for: paged, in: Self.scope) == "edited wire text")
    }

    @Test("Typed preview text stays on its own reply when another reply has its own")
    func typedPreviewIsPerReply() {
        let groups = ReplyMessageGroup.groups(from: partialWindow)
        let first = try! #require(groups.first)
        let second = try! #require(groups.last)
        #expect(first.id != second.id)

        var drafts = ReplyDrafts()
        drafts.update(for: first, in: Self.scope) { $0.insert(note("On the first.")) }
        drafts.update(for: second, in: Self.scope) { $0.insert(note("On the second.")) }
        drafts.setTypedPreview("first text", for: first, in: Self.scope)
        drafts.setTypedPreview("second text", for: second, in: Self.scope)

        #expect(drafts.typedPreview(for: first, in: Self.scope) == "first text")
        #expect(drafts.typedPreview(for: second, in: Self.scope) == "second text")
    }

    /// The preview opens only on a reply with marks, and a first mark creates
    /// the anchor — so a write with no anchor is a caller bug, and minting an
    /// anchor for it would pin text to a line with nothing written on it.
    @Test("Typed preview text is not kept for a reply that has no marks")
    func typedPreviewNeedsAnAnchor() {
        let reply = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)

        var drafts = ReplyDrafts()
        drafts.setTypedPreview("orphan", for: reply, in: Self.scope)

        #expect(drafts.typedPreview(for: reply, in: Self.scope) == nil)
        #expect(drafts.annotatedSeqs(in: Self.scope).isEmpty)

        // The reply's first mark takes the same `seq` an orphan write would
        // have minted, so text stashed under a private anchor would surface
        // now. Both assertions above pass for that mutant (cold code review,
        // 2026-09-13); only this one sees it.
        drafts.update(for: reply, in: Self.scope) { $0.insert(note("First mark.")) }
        #expect(drafts.typedPreview(for: reply, in: Self.scope) == nil)
    }

    @Test("Typed preview text does not resolve in another session or after a rewrite")
    func typedPreviewIsScoped() {
        let reply = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)
        let rewritten = ReplyDrafts.Scope(session: Self.session, generation: 1)
        let otherSession = ReplyDrafts.Scope(session: "session-two", generation: 0)

        var drafts = ReplyDrafts()
        drafts.update(for: reply, in: Self.scope) { $0.insert(note("Say why here.")) }
        drafts.setTypedPreview("scoped text", for: reply, in: Self.scope)

        #expect(drafts.typedPreview(for: reply, in: Self.scope) == "scoped text")
        #expect(drafts.typedPreview(for: reply, in: rewritten) == nil)
        #expect(drafts.typedPreview(for: reply, in: otherSession) == nil)
    }

    /// `Discard edits` passes `nil`; a delivery calls `clear(for:in:)`.
    @Test("Typed preview text is dropped by nil and by clearing the reply")
    func typedPreviewClears() {
        let reply = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)

        var drafts = ReplyDrafts()
        drafts.update(for: reply, in: Self.scope) { $0.insert(note("Say why here.")) }
        drafts.setTypedPreview("discard me", for: reply, in: Self.scope)
        #expect(drafts.typedPreview(for: reply, in: Self.scope) == "discard me")
        drafts.setTypedPreview(nil, for: reply, in: Self.scope)
        #expect(drafts.typedPreview(for: reply, in: Self.scope) == nil)

        drafts.setTypedPreview("sent with the marks", for: reply, in: Self.scope)
        #expect(drafts.typedPreview(for: reply, in: Self.scope) == "sent with the marks")
        drafts.clear(for: reply, in: Self.scope)
        #expect(drafts.typedPreview(for: reply, in: Self.scope) == nil)

        // The reply's next first mark re-creates the same anchor — it pins to
        // the reply's last message — so text left behind by a delivery would
        // come back in the box as if never sent. Mutation M2 (clear keeping
        // the text) passed every assertion above; only this one sees it.
        drafts.update(for: reply, in: Self.scope) { $0.insert(note("A new mark after sending.")) }
        #expect(drafts.typedPreview(for: reply, in: Self.scope) == nil)
    }

    /// `isEmpty` gates `Paste` and `annotatedSeqs` exempts a reply from the
    /// history cap. Typed text lives in its own map — once edited it is what
    /// gets sent (`#cm-93`), passed to the gate as `editedText` — so it must
    /// move neither.
    @Test("Typed preview text changes neither the marks nor which replies count as annotated")
    func typedPreviewLeavesMarksAlone() {
        let reply = try! #require(ReplyMessageGroup.groups(from: partialWindow).first)

        var drafts = ReplyDrafts()
        drafts.update(for: reply, in: Self.scope) { $0.insert(note("Say why here.")) }
        let marksBefore = drafts.draft(for: reply, in: Self.scope)
        let annotatedBefore = drafts.annotatedSeqs(in: Self.scope)

        drafts.setTypedPreview("display only", for: reply, in: Self.scope)

        #expect(drafts.draft(for: reply, in: Self.scope) == marksBefore)
        #expect(drafts.draft(for: reply, in: Self.scope).serialized() == marksBefore.serialized())
        #expect(drafts.annotatedSeqs(in: Self.scope) == annotatedBefore)
    }
}
