import Testing
@testable import CmuxAgentJournal

/// cm-128.6 (Scenario 16 and the usage-limit flag): within one agent on one surface, the newest live session decides the
/// state, by `lastOccurredAtMs` and then by `lastSequence`. A running session no longer outranks a newer waiting one.
@Suite("Newest session wins within one agent")
struct AgentLifecycleNewestSessionTests {
    private let surface = "5E7A11AA-0000-4000-8000-000000000001"
    private let workspace = "5E7A11AA-0000-4000-8000-0000000000AA"
    private let agent = "claude_code"

    private func event(
        _ sequence: Int64,
        _ kind: AgentJournalEventKind,
        session: String,
        at occurredAtMs: Int64,
        native: String? = nil,
        detail: String? = nil
    ) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 5_000 + sequence,
            draft: AgentJournalEventDraft(eventId: "e\(sequence)", kind: kind, occurredAtMs: occurredAtMs, source: "claude",
                agentKey: agent, sessionId: session, workspaceId: workspace, surfaceId: surface,
                nativeEvent: native, detail: detail))
    }

    private func fold(_ events: [AgentJournalEvent]) -> AgentLifecycleReducerState {
        var state = AgentLifecycleReducerState()
        for event in events { AgentLifecycleReducer().apply(event, to: &state) }
        return state
    }

    private func phase(_ events: [AgentJournalEvent]) -> AgentLifecyclePhase? {
        fold(events).combinedPhase(surfaceId: surface, agentKey: agent)
    }

    private let limit = (native: "StopFailure", detail: "rate_limit")
    private let notALimit = (native: "StopFailure", detail: "server_error")

    // MARK: Scenario 16, each case

    @Test func aNewerRunningSessionBeatsAnOlderWaitingOne() {
        #expect(phase([event(1, .approvalRequested, session: "old", at: 100),
                       event(2, .turnStarted, session: "new", at: 200)]) == .running)
    }

    @Test func aNewerWaitingSessionBeatsAnOlderRunningOne() {
        #expect(phase([event(1, .turnStarted, session: "old", at: 100),
                       event(2, .approvalRequested, session: "new", at: 200)]) == .needsInput)
    }

    @Test func aTieOnOccurredAtGoesToTheGreaterSequence() {
        let running = event(1, .turnStarted, session: "a", at: 150)
        let waiting = event(2, .approvalRequested, session: "b", at: 150)
        #expect(phase([running, waiting]) == .needsInput)
        let waitingFirst = event(1, .approvalRequested, session: "b", at: 150)
        let runningLast = event(2, .turnStarted, session: "a", at: 150)
        #expect(phase([waitingFirst, runningLast]) == .running)
    }

    @Test func theNewestIsReadByWhenItHappenedNotByWhenItArrived() {
        // The waiting session's event arrives later (greater sequence) but happened earlier.
        #expect(phase([event(1, .turnStarted, session: "new", at: 200),
                       event(2, .approvalRequested, session: "old", at: 100)]) == .running)
    }

    @Test func theSnapshotFollowsTheNewestSessionToo() {
        let state = fold([event(1, .turnStarted, session: "old", at: 100),
                          event(2, .approvalRequested, session: "new", at: 200)])
        let snapshot = state.snapshot()
        #expect(snapshot.phases[surface]?[agent] == .needsInput)
        #expect(snapshot.newestOccurredAtMs[surface]?[agent] == 200)
    }

    @Test func anOlderWaitUnderANewerErrorShowsTheError() {
        #expect(phase([event(1, .approvalRequested, session: "old", at: 100),
                       event(2, .errorReported, session: "new", at: 200)]) == .error)
    }

    @Test func anEndedNewestSessionLeavesTheOlderOneToDecide() {
        #expect(phase([event(1, .turnStarted, session: "old", at: 100),
                       event(2, .approvalRequested, session: "new", at: 200),
                       event(3, .sessionEnded, session: "new", at: 300)]) == .running)
    }

    // MARK: The usage-limit flag is the winning session's own

    private func usageLimit(_ events: [AgentJournalEvent]) -> Bool {
        fold(events).snapshot().usageLimitAgentKeys[surface]?.contains(agent) == true
    }

    @Test func anOlderFlaggedErrorDoesNotFlagANewerPlainOne() {
        // The flagged session arrives last (greater sequence) but is older by occurredAtMs.
        let events = [event(1, .errorReported, session: "new", at: 200, native: notALimit.native, detail: notALimit.detail),
                      event(2, .errorReported, session: "old", at: 100, native: limit.native, detail: limit.detail)]
        #expect(!usageLimit(events))
        // The live projection reads `hasUsageLimit` itself, so it is pinned directly, whatever `snapshot()` does.
        #expect(!fold(events).hasUsageLimit(surfaceId: surface, agentKey: agent))
    }

    @Test func aNewerIdleSessionLeavesNoFlagFromAnOlderLimitError() {
        let events = [event(1, .errorReported, session: "old", at: 100, native: limit.native, detail: limit.detail),
                      event(2, .turnStarted, session: "new", at: 200),
                      event(3, .turnCompleted, session: "new", at: 300)]
        #expect(phase(events) == .idle)
        #expect(!usageLimit(events))
    }

    @Test func aNewerFlaggedErrorFlagsTheAgent() {
        let events = [event(1, .errorReported, session: "old", at: 100, native: notALimit.native, detail: notALimit.detail),
                      event(2, .errorReported, session: "new", at: 200, native: limit.native, detail: limit.detail)]
        #expect(usageLimit(events))
        #expect(fold(events).hasUsageLimit(surfaceId: surface, agentKey: agent))
    }

    @Test func theStartupReplayAgreesWithTheLiveFlag() {
        let snapshot = fold([event(1, .errorReported, session: "new", at: 200, native: notALimit.native, detail: notALimit.detail),
                             event(2, .errorReported, session: "old", at: 100, native: limit.native, detail: limit.detail)]).snapshot()
        let replayed = AgentJournalReplayPolicy().startupSnapshot(from: snapshot)
        #expect(replayed.phases[surface]?[agent] == .error)
        #expect(replayed.usageLimitAgentKeys[surface]?.contains(agent) != true)
    }
}
