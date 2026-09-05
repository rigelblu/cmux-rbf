import Foundation
import Testing

@testable import CmuxAgentChat

/// The turn gate: has the **newest** turn ended?
///
/// It refuses `Paste & Send` and nothing else. `Paste` types at any point in
/// a turn because it submits nothing, and a wrong *target* — a session that
/// no longer matches — is a different rule that refuses both. Any assertion
/// here that states one of those as an absolute has collapsed the pair.
@Suite("ReplyPanelTurnGate")
struct ReplyPanelTurnGateTests {
    private func group(_ id: String, seq: Int) -> ReplyMessageGroup {
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
                    kind: .prose(ChatProse(text: "reply \(id)")),
                    apiMessageID: id
                )
            ]
        )
    }

    private func boundModel(running: Bool) -> ReplyPanelModel {
        var model = ReplyPanelModel()
        model.bind(sessionID: "session-A", agentIsRunning: running)
        return model
    }

    @Test("A turn still being written closes the gate")
    func writingTurnClosesTheGate() {
        var model = boundModel(running: true)
        model.apply(groups: [group("A", seq: 1)])

        #expect(model.isNewestTurnWriting)
    }

    @Test("The bound session's Stop opens the gate")
    func stopOpensTheGate() {
        var model = boundModel(running: true)
        model.apply(groups: [group("A", seq: 1)])

        model.markTurnFinished(sessionID: "session-A")

        #expect(!model.isNewestTurnWriting)
    }

    @Test("Another session's Stop leaves the gate closed")
    func aStraySessionsStopDoesNotOpenIt() {
        var model = boundModel(running: true)
        model.apply(groups: [group("A", seq: 1)])

        model.markTurnFinished(sessionID: "session-B")

        #expect(model.isNewestTurnWriting)
    }

    // MARK: - The third settle path

    @Test("A turn whose Stop never fires settles on the next user message")
    func aUserMessageSettlesATurnWhoseStopNeverFired() {
        // Crash, uninstalled hook, killed process: `.stop` never arrives.
        // There is no timeout anywhere in `Reply/` — a grep for
        // `Timer|Task.sleep|asyncAfter|timeout` returns nothing — so without
        // this path `Paste & Send` is disabled for the life of the session
        // and `L3`'s copy, "Paste & Send returns when this turn ends",
        // promises something that never happens.
        var model = boundModel(running: true)
        model.apply(groups: [group("A", seq: 1)])
        #expect(model.isNewestTurnWriting)

        // A user message provably ends the prior turn: `groups(from:)`
        // already closes a run on one, so the signal is parsed and was
        // merely unused. The store reports it before applying the new
        // groups, so the turn being settled here is the one that just ended.
        model.markTurnStarted(sessionID: "session-A")

        #expect(!model.isNewestTurnWriting)
    }

    @Test("Another session's user message settles nothing here")
    func aStraySessionsUserMessageSettlesNothing() {
        var model = boundModel(running: true)
        model.apply(groups: [group("A", seq: 1)])

        model.markTurnStarted(sessionID: "session-B")

        #expect(model.isNewestTurnWriting)
    }

    @Test("The reply that arrives after a user message is unfinished again")
    func theNextTurnIsWritingAgain() {
        var model = boundModel(running: true)
        model.apply(groups: [group("A", seq: 1)])
        model.markTurnStarted(sessionID: "session-A")
        #expect(!model.isNewestTurnWriting)

        // Settling the previous turn must not settle the one after it. The
        // anchor is pinned to a message inside turn A, so a newer turn
        // simply is not the finished one.
        model.apply(groups: [group("A", seq: 1), group("B", seq: 2)])

        #expect(model.isNewestTurnWriting)
    }

    // MARK: - The gate is about the newest turn, not the one on screen

    @Test("Reading an older reply does not open the gate while the newest is writing")
    func steppingBackDoesNotOpenTheGate() {
        var model = boundModel(running: true)
        model.apply(groups: [group("A", seq: 1), group("B", seq: 2)])
        model.view(groupID: "A")

        // The reply on screen is finished by construction — a completed
        // reply cannot grow — but the agent is still busy, and a submit
        // would land in the middle of its turn.
        #expect(model.isNewestTurnWriting)
    }

    @Test("An older reply is a deliverable target once the newest turn has ended")
    func anOlderReplyDeliversOnceSettled() {
        var model = boundModel(running: true)
        model.apply(groups: [group("A", seq: 1), group("B", seq: 2)])
        model.markTurnFinished(sessionID: "session-A")
        model.view(groupID: "A")

        // Annotating a message that is not the newest is a deliberate act,
        // not a staleness bug.
        #expect(!model.isNewestTurnWriting)
        #expect(model.viewedGroupID == "A")
    }

    @Test("A model with nothing loaded is not writing, so the gate never hangs open on emptiness")
    func nothingLoadedIsNotWriting() {
        let model = boundModel(running: true)

        #expect(!model.isNewestTurnWriting)
    }
}
