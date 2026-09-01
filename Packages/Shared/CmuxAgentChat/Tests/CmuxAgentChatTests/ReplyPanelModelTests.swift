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
        model.apply(groups: [
            group("msg_A", seq: 1, text: "First."),
            group("msg_B", seq: 2, text: "Second."),
            group("msg_C", seq: 3, text: "Third."),
        ])

        #expect(reading(model.state)?.group.id == "msg_A")
        #expect(reading(model.state)?.position == ReplyPanelPosition(index: 1, total: 3))
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
}
