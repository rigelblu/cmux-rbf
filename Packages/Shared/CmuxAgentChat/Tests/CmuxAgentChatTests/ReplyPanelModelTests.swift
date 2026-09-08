import Foundation
import Testing

@testable import CmuxAgentChat

/// The Reply panel's state machine.
///
/// The three no-message states are asserted apart from each other on
/// purpose: they are one `if` away from collapsing into a single "empty",
/// and the whole point of drawing them separately was that they tell the
/// user different things to do.
@Suite("ReplyPanelModel")
struct ReplyPanelModelTests {
    private func group(_ id: String, seq: Int, text: String) -> ReplyMessageGroup {
        ReplyMessageGroup(
            id: id,
            seq: seq,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            messages: [
                ChatMessage(
                    id: "line-\(seq)",
                    seq: seq,
                    role: .agent,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
                    kind: .prose(ChatProse(text: text)),
                    apiMessageID: id
                )
            ]
        )
    }

    private func message(seq: Int, text: String, apiMessageID: String) -> ChatMessage {
        ChatMessage(
            id: "line-\(seq)",
            seq: seq,
            role: .agent,
            timestamp: Date(timeIntervalSince1970: TimeInterval(seq)),
            kind: .prose(ChatProse(text: text)),
            apiMessageID: apiMessageID
        )
    }

    private func reading(_ state: ReplyPanelState) -> ReplyPanelReading? {
        guard case let .showing(reading) = state else { return nil }
        return reading
    }

    // MARK: - The three no-message states

    @Test("A fresh model has no agent")
    func startsUnbound() {
        #expect(ReplyPanelModel().state == .noAgent)
    }

    @Test("Bound with no reply yet is waiting, not no-agent")
    func boundAndSilentIsWaiting() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: true)

        #expect(model.state == .waiting)
    }

    @Test("An unreadable transcript is a fault, not silence")
    func unreadableIsItsOwnState() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.markUnreadable()

        #expect(model.state == .unavailable)
    }

    @Test("A read fault outranks having replies to show")
    func unreadableOutranksLoadedReplies() {
        // Otherwise the panel keeps rendering a stale reply as though it were
        // live, and the user has no way to learn the tail stopped working.
        var model = ReplyPanelModel()
        model.apply(groups: [group("msg_A", seq: 1, text: "Hello.")])
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.markUnreadable()

        #expect(model.state == .unavailable)
    }

    @Test("Unbinding clears the replies it was showing")
    func unbindClearsReplies() {
        var model = ReplyPanelModel()
        model.apply(groups: [group("msg_A", seq: 1, text: "Hello.")])
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.unbind()

        #expect(model.state == .noAgent)
        #expect(model.groups.isEmpty)
    }

    // MARK: - Showing a reply

    @Test("Following shows the newest reply")
    func followsNewest() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
        ])

        #expect(reading(model.state)?.group.id == "msg_B")
        // The newest reply reads `N of N` (Tom, 2026-09-08). `N` is
        // `reply.maxMessagesBack` capped by what exists — two replies loaded,
        // so `2 of 2` rather than `2 of 5` with three places that do not.
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 2, total: 2))
    }

    @Test("A new reply grows the counter and moves the view while following")
    func newReplyAdvancesWhileFollowing() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "First.")])
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
        ])

        #expect(reading(model.state)?.group.id == "msg_B")
        #expect(reading(model.state)?.position.total == 2)
    }

    @Test("Position reads 1-based, as a person reads it")
    func positionIsOneBased() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "Only.")])

        let showing = reading(model.state)
        #expect(showing?.position == ReplyPanelPosition(index: 1, total: 1))
        #expect(showing?.canStepBack == false)
        #expect(showing?.canStepForward == false)
    }

    // MARK: - Writing vs finished

    @Test("Cold open on a running agent shows the newest reply as writing")
    func coldOpenWhileRunningIsWriting() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: true)
        model.apply(groups: [group("msg_A", seq: 1, text: "Half a th")])

        #expect(reading(model.state)?.isWriting == true)
    }

    @Test("Cold open on an idle agent shows the newest reply as finished")
    func coldOpenWhileIdleIsFinished() {
        // The Stop event for this reply fired before the panel existed, so
        // the lifecycle is the only thing that can answer. Binding before the
        // replies load is the ordinary order, and the answer has to survive
        // the wait.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "All done.")])

        #expect(reading(model.state)?.isWriting == false)
    }

    @Test("The cold-open answer applies whichever order bind and load arrive in")
    func coldOpenSettleIsOrderIndependent() {
        var model = ReplyPanelModel()
        model.apply(groups: [group("msg_A", seq: 1, text: "All done.")])
        model.bind(sessionID: "s1", agentIsRunning: false)

        #expect(reading(model.state)?.isWriting == false)
    }

    @Test("A reply written after a cold-open bind is writing, not finished")
    func coldOpenAnswerIsNotReusedForLaterReplies() {
        // The lifecycle described the reply that existed at bind. Applying it
        // again to the next reply would mark a reply finished the instant its
        // first block lands.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "All done.")])
        model.apply(groups: [
            group("msg_A", seq: 1, text: "All done."),
            group("msg_B", seq: 2, text: "Starting the ne"),
        ])

        #expect(reading(model.state)?.isWriting == true)
    }

    @Test("The turn ending finishes the reply on screen")
    func stopFinishesTheReply() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: true)
        model.apply(groups: [group("msg_A", seq: 1, text: "Done now.")])
        #expect(reading(model.state)?.isWriting == true)

        model.markTurnFinished(sessionID: "s1")

        #expect(reading(model.state)?.isWriting == false)
    }

    @Test("A reply arriving in a NEW turn is writing again")
    func nextReplyIsWritingAgain() {
        // `markTurnStarted` is what makes this case distinguishable, and it
        // is the whole reason that call exists. Without it this sequence is
        // byte-identical to `stopBeforeTheReplyLandsSettlesItOnArrival`
        // below, where the same late group is the *finished* turn's tail.
        // The model cannot tell those apart from the groups alone — so the
        // caller has to say which happened. This test used to assert the
        // "new turn" answer for both, which is what stranded a finished
        // reply as writing whenever a Stop beat its own last prose line.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: true)
        model.apply(groups: [group("msg_A", seq: 1, text: "First.")])
        model.markTurnFinished(sessionID: "s1")

        model.markTurnStarted(sessionID: "s1")
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Sec"),
        ])

        #expect(reading(model.state)?.isWriting == true)
    }

    @Test("Another session's turn start does not reopen this panel's window")
    func otherSessionTurnStartIsIgnored() {
        var model = ReplyPanelModel()
        model.load(
            groups: [group("msg_A", seq: 1, text: "First.")],
            hasMoreHistory: false,
            sessionID: "s1",
            agentIsRunning: true
        )
        model.markTurnFinished(sessionID: "s1")
        model.markTurnStarted(sessionID: "s2")

        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Late tail."),
        ])

        #expect(reading(model.state)?.isWriting == false)
    }

    // MARK: - Holding position on an earlier reply

    @Test("A reply stepped back to is finished even while the agent writes")
    func steppedBackReplyIsNeverWriting() {
        // Reading reply 1 while the agent writes reply 2 must not mute reply
        // 1 — it is complete, and later it must stay annotatable while the
        // next one streams.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: true)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "Finished a while ago."),
            group("msg_B", seq: 2, text: "Still wri"),
        ])
        model.view(groupID: "msg_A")

        #expect(reading(model.state)?.isWriting == false)
        #expect(reading(model.state)?.group.id == "msg_A")
    }

    @Test("Holding position keeps the reply while the counter grows")
    func holdingPositionSurvivesANewReply() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
        ])
        model.view(groupID: "msg_A")
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 2))

        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
            group("msg_C", seq: 3, text: "Third."),
        ])

        #expect(reading(model.state)?.group.id == "msg_A")
        // `n` holds at 1 — this reply is still the oldest shown — while `N`
        // grows 2 → 3 as the window fills. The *content* is what this test
        // protects; the number moving is expected and not promised against.
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 3))
    }

    @Test("Paging older history keeps you on the reply you were reading")
    func pagingKeepsPositionWhenTheHeadTurnGrows() {
        // The oldest loaded turn routinely starts mid-answer: the window is
        // bounded (600 / 300 / 4000) and nothing aligns it to turn
        // boundaries. Paging completes that turn, which moves its first
        // message and so its id. Pinning by id sent you to the newest reply
        // for pressing `◄` at the oldest one.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_B", seq: 5, text: "…the rest of it."),
            group("msg_C", seq: 6, text: "Second."),
        ])
        model.view(groupID: "msg_B")

        // The page lands: the head turn now starts at seq 4 and is named
        // after `msg_A`, while still holding the seq-5 message being read.
        model.apply(groups: [
            ReplyMessageGroup(
                id: "msg_A",
                seq: 4,
                timestamp: Date(timeIntervalSince1970: 4),
                messages: [
                    message(seq: 4, text: "Let me check.", apiMessageID: "msg_A"),
                    message(seq: 5, text: "…the rest of it.", apiMessageID: "msg_B"),
                ]
            ),
            group("msg_C", seq: 6, text: "Second."),
        ])

        #expect(reading(model.state)?.group.id == "msg_A")
        // The older of two loaded replies, so `1 of 2`.
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 2))
    }

    @Test("A settled reply stays settled when its turn grows by paging")
    func settleSurvivesTheHeadTurnGrowing() {
        // `finishedGroupID` is the same kind of pin, so it fails the same
        // way: a settled reply would flip back to `writing` for the sole
        // reason that older history arrived.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_B", seq: 5, text: "Done.")])

        #expect(reading(model.state)?.isWriting == false)

        model.apply(groups: [
            ReplyMessageGroup(
                id: "msg_A",
                seq: 4,
                timestamp: Date(timeIntervalSince1970: 4),
                messages: [
                    message(seq: 4, text: "Let me check.", apiMessageID: "msg_A"),
                    message(seq: 5, text: "Done.", apiMessageID: "msg_B"),
                ]
            )
        ])

        #expect(reading(model.state)?.isWriting == false)
    }

    @Test("Landing on the newest resumes following")
    func viewingTheNewestResumesFollowing() {
        // Otherwise stepping forward to the newest would pin you there, and
        // the next reply would silently not appear.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
        ])
        model.view(groupID: "msg_A")
        model.view(groupID: "msg_B")

        #expect(model.viewedGroupID == nil)

        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
            group("msg_C", seq: 3, text: "Third."),
        ])
        #expect(reading(model.state)?.group.id == "msg_C")
    }

    @Test("A pin whose reply is gone falls back to the newest")
    func stalePinFallsBackToNewest() {
        // History eviction and a transcript rewrite can both take the pinned
        // reply away. An empty panel would be a worse answer than the newest.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
        ])
        model.view(groupID: "msg_A")
        model.apply(groups: [group("msg_B", seq: 2, text: "Second.")])

        #expect(reading(model.state)?.group.id == "msg_B")
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 1))
    }

    @Test("A turn ending in another session leaves this panel writing")
    func stopFromAnotherSessionIsIgnored() {
        // Many agents run at once and their turns end constantly. A panel
        // that settled on any Stop would call a reply finished while this
        // agent was still mid-sentence.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: true)
        model.apply(groups: [group("msg_A", seq: 1, text: "Still wri")])

        model.markTurnFinished(sessionID: "s2")

        #expect(reading(model.state)?.isWriting == true)
    }

    @Test("A turn ending before the panel binds settles nothing")
    func stopBeforeBindIsIgnored() {
        var model = ReplyPanelModel()
        model.apply(groups: [group("msg_A", seq: 1, text: "Something.")])

        model.markTurnFinished(sessionID: "s1")
        model.bind(sessionID: "s1", agentIsRunning: true)

        #expect(reading(model.state)?.isWriting == true)
    }

    @Test("Unbinding forgets which session to listen for")
    func unbindClearsTheSessionBinding() {
        // Otherwise a Stop arriving after the workspace lost its agent would
        // still be accepted by a panel that has nothing to settle.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: true)
        model.unbind()

        #expect(model.sessionID == nil)
    }

    // MARK: - Stepping

    @Test("Stepping back walks to the older reply and holds there")
    func stepBackWalksOlder() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
            group("msg_C", seq: 3, text: "Third."),
        ])

        #expect(model.stepBack() == true)
        #expect(reading(model.state)?.group.id == "msg_B")
        #expect(model.stepBack() == true)
        #expect(reading(model.state)?.group.id == "msg_A")
    }

    @Test("Stepping back at the oldest loaded reply reports it did not move")
    func stepBackStopsAtTheOldestLoaded() {
        // The caller uses this to tell "nothing older is loaded" from
        // "nothing older exists", and pages only in the first case.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "Only.")])

        #expect(model.stepBack() == false)
        #expect(reading(model.state)?.group.id == "msg_A")
    }

    @Test("Stepping forward to the newest resumes following")
    func stepForwardResumesFollowing() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
        ])
        model.stepBack()

        #expect(model.stepForward() == true)
        #expect(model.viewedGroupID == nil)
    }

    @Test("Stepping forward at the newest reports it did not move")
    func stepForwardStopsAtTheNewest() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "Only.")])

        #expect(model.stepForward() == false)
    }

    @Test("Paged-in replies become the ones stepping walks")
    func pagingExtendsTheWalk() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_B", seq: 2, text: "Second.")])
        model.noteHistory(hasMore: true)
        #expect(model.stepBack() == false)

        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
        ])
        model.noteHistory(hasMore: false)

        #expect(model.stepBack() == true)
        #expect(reading(model.state)?.group.id == "msg_A")
    }

    @Test("Returning to the newest resumes following, from any distance")
    func returnToNewestResumesFollowing() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
            group("msg_C", seq: 3, text: "Third."),
        ])
        model.stepBack()
        model.stepBack()
        #expect(reading(model.state)?.group.id == "msg_A")

        #expect(model.returnToNewest() == true)

        #expect(reading(model.state)?.group.id == "msg_C")
        // Following, not merely parked on the last one: the next reply must
        // appear without another press.
        #expect(model.viewedGroupID == nil)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
            group("msg_C", seq: 3, text: "Third."),
            group("msg_D", seq: 4, text: "Fourth."),
        ])
        #expect(reading(model.state)?.group.id == "msg_D")
    }

    @Test("Returning when already newest reports it did not move")
    func returnToNewestWhileFollowingIsANoOp() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "Only.")])

        #expect(model.returnToNewest() == false)
    }

    // MARK: - Offering the controls

    @Test("Back is offered at the oldest loaded reply when more is on disk")
    func backOfferedWhenHistoryRemains() {
        // Offering it only for loaded replies would make a bounded backfill
        // look like the start of the conversation.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "Only.")])
        model.noteHistory(hasMore: true)

        #expect(reading(model.state)?.canStepBack == true)
    }

    @Test("Back is withheld at the true start of the conversation")
    func backWithheldAtTheStart() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "Only.")])
        model.noteHistory(hasMore: false)

        #expect(reading(model.state)?.canStepBack == false)
        #expect(reading(model.state)?.canStepForward == false)
    }

    @Test("Forward is offered only while an older reply is being read")
    func forwardOfferedOnlyWhenHeld() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
        ])
        #expect(reading(model.state)?.canStepForward == false)

        model.stepBack()
        #expect(reading(model.state)?.canStepForward == true)
    }

    @Test("A rewritten transcript takes its history with it")
    func resetClearsHistory() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [group("msg_A", seq: 1, text: "Before.")])
        model.noteHistory(hasMore: true)

        model.reset()
        model.apply(groups: [group("msg_B", seq: 1, text: "After.")])

        #expect(model.hasMoreHistory == false)
        #expect(reading(model.state)?.canStepBack == false)
    }

    // MARK: - Reset

    @Test("A rewritten transcript drops everything derived from the old one")
    func resetDropsState() {
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: true)
        model.apply(groups: [group("msg_A", seq: 1, text: "Before the resume.")])
        model.markTurnFinished(sessionID: "s1")

        model.reset()

        #expect(model.state == .waiting)
        #expect(model.groups.isEmpty)
        #expect(model.finishedGroupID == nil)
        #expect(model.viewedGroupID == nil)
    }

    @Test("A reply loaded after a reset is writing, not finished")
    func resetClearsTheFinishedMarker() {
        // The finished marker named an id in a file that no longer exists.
        // Surviving the reset, it would settle whatever reply happens to
        // reuse that id — and in a resumed session, ids do repeat.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: true)
        model.apply(groups: [group("msg_A", seq: 1, text: "Before.")])
        model.markTurnFinished(sessionID: "s1")

        model.reset()
        model.apply(groups: [group("msg_A", seq: 1, text: "After the resu")])

        #expect(reading(model.state)?.isWriting == true)
    }

    // MARK: - Load

    @Test("Switching agents replaces the panel in one step, leaving no trace of the old one")
    func loadReplacesAPreviousSessionWholesale() {
        // The store reaches this after three `await`s. Before `load` existed
        // it cleared the model up front and refilled it afterwards, so the
        // panel rendered its no-agent empty state in between and visibly
        // flashed on every pane switch.
        var model = ReplyPanelModel()
        model.bind(sessionID: "s1", agentIsRunning: false)
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
            group("msg_C", seq: 3, text: "Third."),
        ])
        model.noteHistory(hasMore: true)
        // Stepped back, so a leaked view position would be visible.
        _ = model.stepBack()
        #expect(model.viewedGroupID != nil)

        model.load(
            groups: [group("msg_X", seq: 1, text: "Other agent.")],
            hasMoreHistory: false,
            sessionID: "s2",
            agentIsRunning: false
        )

        #expect(model.sessionID == "s2")
        #expect(model.groups.count == 1)
        // Following the newest again, not holding the old session's position.
        #expect(model.viewedGroupID == nil)
        #expect(model.hasMoreHistory == false)
        let reading = reading(model.state)
        #expect(reading?.group.markdown == "Other agent.")
        #expect(reading?.position.index == 1)
        #expect(reading?.position.total == 1)
        #expect(reading?.canStepBack == false)
        #expect(reading?.canStepForward == false)
    }

    @Test("Load never passes through the empty state")
    func loadNeverShowsNoAgent() {
        // The guarantee the store depends on: one mutation in, one state out.
        // A caller cannot observe an intermediate value because there is no
        // point at which one exists.
        var model = ReplyPanelModel()
        model.load(
            groups: [group("msg_A", seq: 1, text: "Hello.")],
            hasMoreHistory: false,
            sessionID: "s1",
            agentIsRunning: false
        )
        #expect(model.state != .noAgent)
        #expect(model.state != .waiting)
    }

    @Test("Load carries whether older replies remain behind the page")
    func loadCarriesHistoryAvailability() {
        var model = ReplyPanelModel()
        model.load(
            groups: [group("msg_A", seq: 9, text: "Newest only.")],
            hasMoreHistory: true,
            sessionID: "s1",
            agentIsRunning: false
        )
        #expect(model.hasMoreHistory)
        // One group loaded, but stepping back must stay live: the rest is on
        // disk, and the counter is what says so.
        #expect(reading(model.state)?.canStepBack == true)
    }

    @Test("Load settles the newest reply only when the agent is idle")
    func loadAppliesTheLifecycleAnswer() {
        var running = ReplyPanelModel()
        running.load(
            groups: [group("msg_A", seq: 1, text: "Still writ")],
            hasMoreHistory: false,
            sessionID: "s1",
            agentIsRunning: true
        )
        #expect(reading(running.state)?.isWriting == true)

        var idle = ReplyPanelModel()
        idle.load(
            groups: [group("msg_A", seq: 1, text: "All done.")],
            hasMoreHistory: false,
            sessionID: "s1",
            agentIsRunning: false
        )
        #expect(reading(idle.state)?.isWriting == false)
    }

    // MARK: - Stop racing its own reply

    @Test("A Stop that lands before its reply settles that reply when it arrives")
    func stopBeforeTheReplyLandsSettlesItOnArrival() {
        // The Stop hook is a process spawn plus a socket round trip; the
        // transcript's file watcher throttles at 200ms. So a turn's last
        // prose can land *after* the Stop that ended it. Settling "whatever
        // is newest right now" then marks the previous reply and strands the
        // real one, leaving the panel permanently one turn behind — a
        // finished reply muted and captioned as still writing.
        var model = ReplyPanelModel()
        model.load(
            groups: [group("msg_A", seq: 1, text: "First.")],
            hasMoreHistory: false,
            sessionID: "s1",
            agentIsRunning: true
        )

        model.markTurnFinished(sessionID: "s1")
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "The tail that lost the race."),
        ])

        #expect(reading(model.state)?.isWriting == false)
    }

    // MARK: - `cm-69.6` — how far `◄` walks

    /// `count` replies, oldest first, ids `r0`…`r{count-1}` and `seq` `1…count`.
    private func walk(_ count: Int) -> [ReplyMessageGroup] {
        (1...count).map { group("r\($0 - 1)", seq: $0, text: "Reply \($0).") }
    }

    /// The `seq` of the reply `k` back from the newest, for marking it.
    private func seq(reverseIndex k: Int, of groups: [ReplyMessageGroup]) -> Int {
        groups[groups.count - 1 - k].seq
    }

    private func loaded(_ groups: [ReplyMessageGroup], hasMoreHistory: Bool = false) -> ReplyPanelModel {
        var model = ReplyPanelModel()
        model.load(
            groups: groups,
            hasMoreHistory: hasMoreHistory,
            sessionID: "s1",
            agentIsRunning: false
        )
        return model
    }

    @Test("A: `◄` stops after `maxMessagesBack` un-annotated replies")
    func capStopsTheWalk() {
        // Five reachable, four steps between them — with replies still loaded
        // behind, so this is the cap stopping the walk and not the data
        // running out.
        let groups = walk(10)
        var model = loaded(groups)

        for step in 1...4 {
            #expect(model.stepBack() == true, "step \(step) of 4 should move")
        }
        #expect(model.stepBack() == false)

        // Asserted alongside the return value, and this is the assertion that
        // would have caught the design defect a cold review found: a cap
        // expressed as a `stepBack(skipping:)` parameter cannot reach
        // `canStepBack`, which derives inside the parameterless `state`. The
        // two then disagree — the arrow stays lit, the press returns false,
        // and the store pages older history in. A test asserting only the
        // return value passes on the broken design.
        #expect(reading(model.state)?.canStepBack == false)
        // Four steps back from `5 of 5`, so the oldest reply in the window.
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 5))
    }

    @Test("B: an annotated reply does not spend budget and stays reachable")
    func annotatedRepliesStayReachable() {
        // Marks on the 7th and 9th newest, well past a cap of 5. Losing them
        // is the outcome this feature ranks worst, so the exemption is what
        // the whole rule is built around.
        let groups = walk(12)
        var model = loaded(groups)
        model.noteAnnotated(seqs: [
            seq(reverseIndex: 6, of: groups),
            seq(reverseIndex: 8, of: groups),
        ])

        for step in 1...8 {
            #expect(model.stepBack() == true, "step \(step) of 8 should move")
            #expect(reading(model.state)?.group.id == "r\(11 - step)")
        }

        // Standing on the 9th newest — the older mark — with both behind.
        #expect(reading(model.state)?.canStepBack == false)
        #expect(model.stepBack() == false)
        // `N` is what `◄` reaches, so the exemption shows in the number:
        // nine reachable against a configured five. The clamp that hid this
        // lasted about an hour on 2026-09-08 and was rejected on sight.
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 9))
    }

    @Test("B2: the walk crosses un-annotated replies to reach a mark behind them")
    func theWalkIsContiguousPastAMark() {
        // The clause that is easy to leave out. With only the "annotated
        // replies are reachable" half, the 6th newest is out of budget while
        // the 7th is reachable — a set `◄` cannot walk to without skipping.
        let groups = walk(12)
        var model = loaded(groups)
        model.noteAnnotated(seqs: [seq(reverseIndex: 6, of: groups)])

        for _ in 1...5 { #expect(model.stepBack() == true) }
        // Reverse index 5 — the 6th newest, un-annotated and past a budget of
        // 5. Reachable only because the mark at reverse 6 sits behind it, and
        // that is clause 2 doing the only work it ever does.
        #expect(reading(model.state)?.group.id == "r6")
        #expect(reading(model.state)?.canStepBack == true)

        #expect(model.stepBack() == true)
        #expect(reading(model.state)?.group.id == "r5", "the marked reply itself")
        // Nothing is marked behind it, and the budget ran out five replies
        // ago, so the walk ends here rather than continuing on the mark's
        // momentum.
        #expect(model.stepBack() == false)
    }

    @Test("C: a reply that ages past the cap while you stand on it keeps you")
    func agingPastTheCapDoesNotMoveTheReader() {
        // Moving the reader would destroy unsent writing, which this feature
        // ranks above a failed send.
        var groups = walk(5)
        var model = loaded(groups)
        for _ in 1...4 { model.stepBack() }
        #expect(reading(model.state)?.group.id == "r0")

        groups += [
            group("r5", seq: 6, text: "Reply 6."),
            group("r6", seq: 7, text: "Reply 7."),
            group("r7", seq: 8, text: "Reply 8."),
        ]
        model.apply(groups: groups)

        #expect(reading(model.state)?.group.id == "r0")
        // Eight back with a cap of five, so `n` clamps to 1. The counter says
        // the same thing here as on the oldest in-window reply; the `group.id`
        // assertion above is the one that proves nothing moved.
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 5))
    }

    @Test("The oldest-loaded flag names the oldest reply, not the newest")
    func oldestLoadedFlagSurvivesTheCounterInversion() {
        // The regression `cm-69.6` nearly shipped. This gated the "the
        // conversation did not start here" caption via `position.index == 1`,
        // which was the oldest reply while the counter counted up from the
        // oldest — and this slice re-based the counter so `1` is the *newest*.
        // The caption would have appeared over a reply written seconds ago.
        let groups = walk(6)
        var model = loaded(groups)
        #expect(model.isAtOldestLoadedReply == false, "starts on the newest")

        // **The cap must bite, and getting this wrong made the first version
        // of this test worthless.** It raised the cap to 100 so the walk could
        // reach the oldest reply — which makes "oldest reachable" and "oldest
        // loaded" the same reply, the one condition under which the buggy form
        // and the correct one agree. A mutation restoring `index == 1` passed
        // all 493 tests against that fixture.
        model.setMaxMessagesBack(2)
        while model.stepBack() {}

        // At the cap: the oldest *reachable* reply, with four more loaded
        // behind it. The counter reads `1` here — and that is precisely the
        // value the old `position.index == 1` form mistook for "the oldest
        // loaded", which would fire the "the conversation did not start here"
        // caption at the cap, stacked on top of `Showing last`.
        #expect(reading(model.state)?.group.id == "r4")
        #expect(reading(model.state)?.position.index == 1)
        #expect(model.isAtOldestLoadedReply == false, "four replies are still loaded behind this one")

        // Now genuinely at the oldest loaded reply.
        model.setMaxMessagesBack(100)
        while model.stepBack() {}
        #expect(reading(model.state)?.group.id == "r0")
        #expect(model.isAtOldestLoadedReply == true)
    }

    @Test("The oldest-loaded flag is false with nothing bound")
    func oldestLoadedFlagIsFalseWhenNothingShows() {
        // `.waiting` and `.noAgent` must not satisfy it — the caption would
        // otherwise render over an empty panel.
        var model = ReplyPanelModel()
        #expect(model.isAtOldestLoadedReply == false)
        model.bind(sessionID: "s1", agentIsRunning: false)
        #expect(model.isAtOldestLoadedReply == false, "bound but no replies yet")
    }

    @Test("A reply you have marked keeps you when a newer one arrives")
    func markedReplyHoldsPositionAgainstTheNewest() {
        // The 2026-09-01 rule — "follow the newest only while you are already
        // on it and carry no note on it" — whose draft half went unbuilt until
        // 2026-09-08, because nothing in the model could see the drafts.
        // Following would walk the view off the reply you just annotated at
        // the exact moment you would press Paste.
        var groups = walk(3)
        var model = loaded(groups)
        #expect(reading(model.state)?.group.id == "r2", "following the newest")

        model.noteAnnotated(seqs: [seq(reverseIndex: 0, of: groups)])
        groups.append(group("r3", seq: 4, text: "Reply 4."))
        model.apply(groups: groups)

        #expect(reading(model.state)?.group.id == "r2", "held, not followed")
        #expect(reading(model.state)?.canStepForward == true, "the newer reply is still reachable forward")
    }

    @Test("Following resumes for an unmarked reply, which is the control")
    func unmarkedReplyStillFollows() {
        // Without this the test above passes on a model that never follows at
        // all, which would break the panel's whole default behaviour.
        var groups = walk(3)
        var model = loaded(groups)
        groups.append(group("r3", seq: 4, text: "Reply 4."))
        model.apply(groups: groups)

        #expect(reading(model.state)?.group.id == "r3", "no marks, so it follows")
    }

    @Test("C2: removing your last mark shrinks the reachable set under you")
    func unmarkingShrinksTheReachableSet() {
        // The second shrink cause, and the one a fixture that only appends
        // never reaches.
        let groups = walk(12)
        var model = loaded(groups)
        model.noteAnnotated(seqs: [seq(reverseIndex: 6, of: groups)])
        for _ in 1...6 { model.stepBack() }
        #expect(reading(model.state)?.group.id == "r5")
        // Seven reachable — five of budget plus the two the mark carries.
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 7))

        model.noteAnnotated(seqs: [])

        #expect(reading(model.state)?.group.id == "r5", "the reader must not move")
        // **The counter is identical before and after**, because clamping
        // hides the shrink: `1 of 5` either way. Recorded rather than papered
        // over — the assertion carrying this test is `canStepBack` flipping to
        // false below, and a fixture that only appends never produces this
        // shrink cause at all.
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 5))
        #expect(reading(model.state)?.canStepBack == false)
    }

    @Test("D: a spent budget stops `◄` even with history still on disk")
    func capOutranksHistoryOnDisk() {
        // `cm-69.1` offers `◄` when an older reply is loaded *or* still on
        // disk. That rule wins by default unless the cap explicitly outranks
        // it — and if it does not, the store pages history in at the cap,
        // which is the one thing this slice forbids.
        var model = loaded(walk(10), hasMoreHistory: true)
        for _ in 1...4 { model.stepBack() }

        #expect(model.hasMoreHistory == true)
        #expect(reading(model.state)?.canStepBack == false)
        #expect(model.stepBack() == false)
    }

    @Test("D2: `◄` still pages when the budget outlasts the loaded replies")
    func budgetLeftOverStillPages() {
        // The other side of D, and the one that breaks `cm-69.1` if the cap is
        // written as "stop at the loaded frontier": three loaded, budget 5, so
        // the walk must reach the oldest loaded reply and still offer `◄` for
        // the store to page against.
        var model = loaded(walk(3), hasMoreHistory: true)
        for _ in 1...2 { #expect(model.stepBack() == true) }

        #expect(reading(model.state)?.group.id == "r0")
        #expect(reading(model.state)?.canStepBack == true)
    }

    @Test("The configured cap survives a session change")
    func capOutlivesLoad() {
        // `load` does `self = ReplyPanelModel()`, so a cap held here reverts
        // to the default on every session change unless it is carried across —
        // silently, with nothing on screen saying the user's setting is gone.
        var model = ReplyPanelModel()
        model.setMaxMessagesBack(8)
        model.load(groups: walk(12), hasMoreHistory: false, sessionID: "s2", agentIsRunning: false)

        #expect(model.maxMessagesBack == 8)
        for _ in 1...7 { #expect(model.stepBack() == true) }
        #expect(model.stepBack() == false)
    }

    @Test("A cap below 1 is clamped rather than trusted")
    func capIsClamped() {
        // `0` would leave `◄` permanently dead, which reads as a broken panel
        // rather than a configured one.
        var model = ReplyPanelModel()
        model.setMaxMessagesBack(0)
        #expect(model.maxMessagesBack == 1)

        model.load(groups: walk(5), hasMoreHistory: false, sessionID: "s1", agentIsRunning: false)
        #expect(model.stepBack() == false)
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 1))
    }

    @Test("A rewritten transcript drops the annotated seqs it carried")
    func resetClearsAnnotations() {
        // A `seq` is a line index, so the new file has one at every old
        // number. Left behind, these exempt replies nobody marked.
        let groups = walk(12)
        var model = loaded(groups)
        model.noteAnnotated(seqs: [seq(reverseIndex: 8, of: groups)])
        #expect(model.reachableCount == 9)

        model.reset()
        model.apply(groups: groups)

        #expect(model.reachableCount == 5)
    }
}
