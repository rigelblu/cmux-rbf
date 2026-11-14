import Foundation
import Testing
@testable import CmuxAgentJournal

struct AgentLifecycleMonitoringTests {
    private let workspace = "11111111-1111-1111-1111-111111111111"
    private let surface = "22222222-2222-2222-2222-222222222222"

    private func event(_ sequence: Int64, _ kind: AgentJournalEventKind,
                       source: String = "claude", pending: Bool = false, child: String? = nil,
                       phase: AgentLifecyclePhase? = nil, identity: String? = nil,
                       turn: String? = nil, notify: Bool = false, isSubagent: Bool = false) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: sequence,
            draft: AgentJournalEventDraft(eventId: "event-\(sequence)", kind: kind,
                occurredAtMs: sequence, source: source, agentKey: source, sessionId: "session",
                workspaceId: workspace, surfaceId: surface, isSubagent: isSubagent, pendingWork: pending,
                nativeEvent: kind == .stateChanged && phase == .unknown ? "ClearAgentState" : nil,
                declaredPhase: phase, attention: AgentAttentionContext(eventIdentity: identity,
                    turnIdentity: turn, requestIdentity: child,
                    notification: notify ? AgentJournalNotification(title: "Agent", subtitle: "", body: "Finished",
                        category: "turn-complete") : nil)))
    }

    private func fold(_ events: [AgentJournalEvent]) -> (
        snapshot: AgentLifecycleSnapshot, decisions: [AgentNotificationDecision], converted: [AgentJournalEvent]
    ) {
        var reconciler = AgentNotificationReconciler()
        var state = AgentLifecycleReducerState()
        let reducer = AgentLifecycleReducer()
        var decisions: [AgentNotificationDecision] = []
        var converted: [AgentJournalEvent] = []
        for event in events {
            let decision = reconciler.apply(event)
            let lifecycle = reconciler.lifecycleEvent(event)
            decisions.append(decision)
            converted.append(lifecycle)
            if decision.projectsLifecycle { reducer.apply(lifecycle, to: &state) }
        }
        return (state.snapshot(), decisions, converted)
    }

    @Test func backgroundStopProjectsMonitoringAndAdmitsItsCompletion() {
        let result = fold([event(1, .turnStarted, identity: "prompt-1"),
            event(2, .turnCompleted, pending: true, notify: true)])
        #expect(result.snapshot.phases[surface]?["claude"] == .monitoring)
        #expect(result.converted.last?.draft.kind == .stateChanged)
        #expect(result.converted.last?.draft.declaredPhase == .monitoring)
        #expect(result.decisions.last?.disposition == .accepted)
    }

    @Test(arguments: ["claude", "codex"], [false, true])
    func pendingStopsUnderAHandOrLiveHelperStayDelayed(source: String, hasRequest: Bool) {
        let result = fold([event(1, .turnStarted, source: source),
            event(2, hasRequest ? .questionRequested : .childSpawned, source: source,
                child: "pending", notify: hasRequest),
            event(3, .turnCompleted, source: source, pending: true, notify: true)])
        #expect(result.snapshot.phases[surface]?[source] == (hasRequest ? .needsInput : .running))
        #expect(result.decisions.last?.disposition == .delayed)
    }

    @Test func aCodexPendingStopKeepsTheSpinnerAndDelaysCompletion() {
        let result = fold([event(1, .turnStarted, source: "codex"),
            event(2, .turnCompleted, source: "codex", pending: true, notify: true)])
        #expect(result.snapshot.phases[surface]?["codex"] == .running)
        #expect(result.decisions.last?.disposition == .delayed)
    }

    @Test(arguments: [false, true])
    func codexChildHookAndFeedPathsKeepTheParentRunningUntilTheSettledStop(viaWrapperHook: Bool) {
        let child = viaWrapperHook ? nil : "feed-child"
        let prefix = [event(1, .turnStarted, source: "codex", turn: "parent-turn"),
            event(2, .childSpawned, source: "codex", child: child, isSubagent: viaWrapperHook),
            event(3, .turnCompleted, source: "codex", pending: true, turn: "parent-turn", notify: true)]
        let pending = fold(prefix)
        #expect(pending.decisions[1].disposition == (viaWrapperHook ? .subagent : .observation))
        #expect(pending.snapshot.phases[surface]?["codex"] == .running)
        #expect(pending.decisions.last?.disposition == .delayed)
        let settled = fold(prefix + [
            event(4, .childCompleted, source: "codex", child: child, isSubagent: viaWrapperHook),
            event(5, .turnCompleted, source: "codex", turn: "parent-turn", notify: true)])
        #expect(settled.snapshot.phases[surface]?["codex"] == .idle)
        #expect(settled.decisions.last?.disposition == .accepted)
    }

    @Test func rawPendingWorkStillMeansRunningAndMonitoringHasItsOwnRank() {
        var state = AgentLifecycleReducerState()
        AgentLifecycleReducer().apply(event(1, .turnCompleted, pending: true), to: &state)
        #expect(state.snapshot().phases[surface]?["claude"] == .running)
        let order: [AgentLifecyclePhase] = [.running, .needsInput, .monitoring, .error, .unknown, .idle]
        #expect(order.map(\.combinePrecedence) == [6, 5, 4, 3, 2, 1])
    }

    @Test(arguments: [AgentJournalEventKind.sessionStarted, .idleObserved, .attentionResolved,
                      .childCompleted, .childFailed])
    func observationsAndResolutionsDoNotLoseTheWatchingFlag(kind: AgentJournalEventKind) {
        let isChild = kind == .childCompleted || kind == .childFailed
        let source = isChild ? "agy" : "claude"
        let prefix = [event(1, .turnStarted, source: source),
            event(2, .turnCompleted, source: source, pending: true)]
        #expect(fold(prefix).snapshot.phases[surface]?[source] == .monitoring)
        let result = fold(prefix + [event(3, kind, source: source, pending: kind == .idleObserved, child: "unseen")])
        if isChild { #expect(result.decisions.last?.projectsLifecycle == true) }
        #expect(result.snapshot.phases[surface]?[source] == .monitoring)
        #expect(result.converted.last?.draft.declaredPhase == .monitoring)
    }

    @Test(arguments: [AgentJournalEventKind.turnStarted, .stateChanged, .childSpawned, .turnCompleted,
                      .sessionEnded])
    func realActivityOrASettledStopClearsWatching(kind: AgentJournalEventKind) {
        var events = [event(1, .turnStarted), event(2, .turnCompleted, pending: true),
            event(3, kind, child: "child", phase: kind == .stateChanged ? .running : nil)]
        // A later conversion also sees the cleared flag; a raw turnStarted alone masks it.
        if kind != .sessionEnded { events.append(event(4, .sessionStarted)) }
        let result = fold(events)
        let expected: AgentLifecyclePhase? = kind == .sessionEnded ? nil : (kind == .turnCompleted ? .idle : .running)
        #expect(result.snapshot.phases[surface]?["claude"] == expected)
    }

    @Test func clearForgetsWatchingEvenAfterAnIdleOrChildObservation() {
        let prefix = [event(1, .turnStarted), event(2, .turnCompleted, pending: true),
            event(3, .stateChanged, phase: .unknown)]
        #expect(fold(prefix + [event(4, .childCompleted, child: "unseen")])
            .snapshot.phases[surface]?["claude"] == .unknown)
        #expect(fold(prefix + [event(4, .idleObserved, pending: true)])
            .snapshot.phases[surface]?["claude"] == .unknown)
        #expect(fold(prefix + [event(4, .turnCompleted, pending: true)])
            .snapshot.phases[surface]?["claude"] == .monitoring)
        #expect(fold(prefix + [event(4, .questionRequested, child: "new-question", notify: true),
            event(5, .attentionResolved, pending: true, child: "new-question")])
            .snapshot.phases[surface]?["claude"] == .running)
    }

    @Test func aLiveHelperIsWorkAndItsToolCallAlsoEndsWatching() {
        let helper = fold([event(1, .turnStarted), event(2, .childSpawned, child: "helper"),
            event(3, .turnCompleted, pending: true)])
        #expect(helper.snapshot.phases[surface]?["claude"] == .running)
        let missedStart = fold([event(1, .turnStarted), event(2, .turnCompleted, pending: true),
            event(3, .stateChanged, phase: .running), event(4, .childCompleted, child: "helper")])
        #expect(missedStart.snapshot.phases[surface]?["claude"] == .running)
    }

    @Test func aClaudeStopWithNoPendingWorkForgetsALostChildStop() {
        let result = fold([event(1, .turnStarted), event(2, .childSpawned, child: "lost-stop"),
            event(3, .turnCompleted, notify: true)])
        #expect(result.snapshot.phases[surface]?["claude"] == .idle)
        #expect(result.decisions.last?.disposition == .accepted)
    }

    @Test func anUnseenClaudeChildStopCannotPoisonALaterStartWithTheSameID() {
        let result = fold([event(1, .turnStarted), event(2, .childCompleted, child: "helper"),
            event(3, .childSpawned, child: "helper"), event(4, .turnCompleted, pending: true)])
        #expect(result.snapshot.phases[surface]?["claude"] == .running)
        #expect(result.decisions[1].projectsLifecycle == false)
    }

    @Test func aRequestKeepsItsHandAndResolvingItReturnsToWatching() {
        let prefix = [event(1, .turnStarted), event(2, .turnCompleted, pending: true),
            event(3, .questionRequested, child: "question", notify: true)]
        #expect(fold(prefix).snapshot.phases[surface]?["claude"] == .needsInput)
        let result = fold(prefix + [event(4, .attentionResolved, child: "question")])
        #expect(result.snapshot.phases[surface]?["claude"] == .monitoring)
    }

    @Test(arguments: [false, true])
    func aResolutionThatResumesWorkClearsWatching(hasRequestIdentity: Bool) {
        let request = hasRequestIdentity ? "question" : nil
        let result = fold([event(1, .turnStarted), event(2, .turnCompleted, pending: true),
            event(3, .questionRequested, child: request, notify: true),
            event(4, .attentionResolved, pending: true, child: request)])
        #expect(result.snapshot.phases[surface]?["claude"] == .running)
    }

    @Test func anAcceptedIdleObservationStillSettlesAWatchingNativeTurn() {
        let prefix = [event(1, .turnStarted, source: "agy", turn: "turn"),
            event(2, .turnCompleted, source: "agy", pending: true, turn: "turn")]
        #expect(fold(prefix).snapshot.phases[surface]?["agy"] == .monitoring)
        let result = fold(prefix + [event(3, .idleObserved, source: "agy", turn: "turn")])
        #expect(result.snapshot.phases[surface]?["agy"] == .idle)
    }

    @Test(arguments: ["idle-observed", "idle", "error", "error-reported"])
    func leavingRunningForASettledOrFailedPhaseForgetsWatching(transition: String) {
        let kind: AgentJournalEventKind = transition == "idle-observed" ? .idleObserved
            : (transition == "error-reported" ? .errorReported : .stateChanged)
        let phase: AgentLifecyclePhase? = transition == "idle" ? .idle : (transition == "error" ? .error : nil)
        let watching = [event(1, .turnStarted, source: "agy", turn: "turn"),
            event(2, .turnCompleted, source: "agy", pending: true, turn: "turn")]
        #expect(fold(watching).snapshot.phases[surface]?["agy"] == .monitoring)
        let prefix = watching + [event(3, kind, source: "agy", phase: phase, turn: "turn")]
        let settled: AgentLifecyclePhase = transition.hasPrefix("idle") ? .idle : .error
        #expect(fold(prefix).snapshot.phases[surface]?["agy"] == settled)
        let result = fold(prefix + [event(4, .attentionResolved, source: "agy", pending: true,
            child: "fresh-resolution", turn: "turn")])
        #expect(result.snapshot.phases[surface]?["agy"] == .running)
    }

    @Test(arguments: [false, true])
    func theDrainGetsADistinctCompletionAndInvalidatesTheFirstNotification(hasPromptIdentity: Bool) throws {
        let result = fold([event(1, .turnStarted, identity: "typed-prompt"),
            event(2, .turnCompleted, pending: true, notify: true),
            event(3, .turnStarted, identity: hasPromptIdentity ? "automatic-drain" : nil),
            event(4, .turnCompleted, notify: true)])
        #expect(result.decisions[1].disposition == .accepted)
        let first = try #require(result.decisions[1].identity)
        let drain = try #require(result.decisions[3].identity)
        #expect(first != drain)
        #expect(result.decisions[2].invalidatedCorrelationKeys == [first])
        #expect(result.snapshot.phases[surface]?["claude"] == .idle)
    }

    @Test(arguments: [false, true])
    func heldChildReleaseAndTheStopClaimOnlyOneFinishedPing(newTurnBeforeRelease: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentJournalStore(databaseURL: root.appendingPathComponent("journal.sqlite"))
        defer { store.close() }
        var events = [event(1, .turnStarted, source: "codex", identity: "prompt"),
            event(2, .childSpawned, source: "codex", child: "helper"),
            event(3, .turnCompleted, source: "codex", notify: true)]
        if newTurnBeforeRelease { events.append(event(4, .turnStarted, source: "codex", identity: "drain")) }
        events += [event(5, .childCompleted, source: "codex", child: "helper"),
            event(6, .turnCompleted, source: "codex", notify: true)]
        var claims = 0
        for decision in fold(events).decisions where decision.disposition == .accepted {
            if let identity = decision.identity, try store.claimNotification(identity: identity) { claims += 1 }
        }
        #expect(claims == 1)
    }

    @Test func monitoringIsDerivedAndNeverAdmittedToStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentJournalStore(databaseURL: root.appendingPathComponent("journal.sqlite"))
        defer { store.close() }
        #expect(throws: AgentJournalStoreError.self) {
            try store.append(event(1, .stateChanged, phase: .monitoring).draft)
        }
        #expect(try store.events(afterSequence: 0, limit: 100).isEmpty)
    }

    @Test func replayDropsMonitoringLikeRunning() {
        let snapshot = fold([event(1, .turnStarted), event(2, .turnCompleted, pending: true)]).snapshot
        #expect(snapshot.phases[surface]?["claude"] == .monitoring)
        #expect(AgentJournalReplayPolicy().startupSnapshot(from: snapshot).phases.isEmpty)
    }
}
