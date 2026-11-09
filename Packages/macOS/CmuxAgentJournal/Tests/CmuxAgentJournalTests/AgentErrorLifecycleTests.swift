import Testing
@testable import CmuxAgentJournal

/// cm-128.5 (Scenario 70), a guard: an error ends on the session's next signal, and only then. `.5` changes no
/// reconciler rule, so this pins the ones it rests on. It passes at base on purpose.
@Suite("Error lifecycle")
struct AgentErrorLifecycleTests {
    private let surface = "5E7A11AA-0000-4000-8000-000000000001"
    private let workspace = "5E7A11AA-0000-4000-8000-0000000000AA"

    private func event(_ sequence: Int64, _ kind: AgentJournalEventKind, pending: Bool = false,
                       declared: AgentLifecyclePhase? = nil, notify: Bool = false, request: String? = nil,
                       detail: String? = nil) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 1_000 + sequence,
            draft: AgentJournalEventDraft(eventId: "e\(sequence)", kind: kind, occurredAtMs: 1_000 + sequence,
                source: "claude", agentKey: "claude_code", sessionId: "s1", workspaceId: workspace, surfaceId: surface,
                pendingWork: pending, nativeEvent: kind == .errorReported ? "StopFailure" : nil, declaredPhase: declared,
                detail: detail,
                attention: AgentAttentionContext(requestIdentity: request, notification: notify
                    ? AgentJournalNotification(title: "Claude Code", subtitle: "", body: "x", category: "other") : nil)))
    }

    /// Folds the way the app does: reconciler first, then the reducer on what it projects.
    private func phase(after events: [AgentJournalEvent]) -> AgentLifecyclePhase? {
        var reconciler = AgentNotificationReconciler()
        var state = AgentLifecycleReducerState()
        for event in events {
            let decision = reconciler.apply(event)
            if decision.disposition != .stale, decision.projectsLifecycle {
                AgentLifecycleReducer().apply(reconciler.lifecycleEvent(event), to: &state)
            }
        }
        return state.combinedPhase(surfaceId: surface, agentKey: "claude_code")
    }

    /// The reducer's state after the same fold as `phase(after:)`, for the usage-limit flag.
    private func usageLimit(after events: [AgentJournalEvent]) -> Bool {
        var reconciler = AgentNotificationReconciler()
        var state = AgentLifecycleReducerState()
        for event in events {
            let decision = reconciler.apply(event)
            if decision.disposition != .stale, decision.projectsLifecycle {
                AgentLifecycleReducer().apply(reconciler.lifecycleEvent(event), to: &state)
            }
        }
        return state.snapshot().usageLimitAgentKeys[surface]?.contains("claude_code") == true
    }

    private var errored: [AgentJournalEvent] { [event(1, .turnStarted), event(2, .errorReported, notify: true)] }

    @Test func anErrorIsTheSessionsPhase() {
        #expect(phase(after: errored) == .error)
    }

    @Test(arguments: [AgentJournalEventKind.idleObserved, .attentionResolved, .childCompleted, .messagePublished])
    func itStaysThroughSignalsThatDoNotEndIt(kind: AgentJournalEventKind) {
        #expect(phase(after: errored + [event(3, kind)]) == .error, "\(kind)")
    }

    @Test func aNewTurnEndsIt() { #expect(phase(after: errored + [event(3, .turnStarted)]) == .running) }
    @Test func aRunningReportEndsIt() { #expect(phase(after: errored + [event(3, .stateChanged, declared: .running)]) == .running) }
    @Test func aLaterCompletionEndsIt() { #expect(phase(after: errored + [event(3, .turnCompleted)]) == .idle) }
    @Test func aQuestionEndsIt() { #expect(phase(after: errored + [event(3, .questionRequested, notify: true)]) == .needsInput) }
    @Test func clearAgentStateEndsIt() { #expect(phase(after: errored + [event(3, .stateChanged, declared: .unknown)]) == .unknown) }
    @Test func theSessionEndingEndsIt() { #expect(phase(after: errored + [event(3, .sessionEnded)]) != .error) }

    // MARK: A signal that does not end an error keeps a usage limit's flag (whole-diff review F4, F7)

    /// A helper (`h`) spawns before the main session stops on a rate limit, then ends while the error stands. Each kind
    /// here reaches the reducer as a `stateChanged` at `.error` (the reconciler's `lifecycleEvent`). A known helper's stop is the
    /// path that really projects; the id-less `childCompleted` in `itStaysThroughSignalsThatDoNotEndIt` returns early.
    @Test(arguments: [AgentJournalEventKind.childCompleted, .idleObserved, .attentionResolved])
    func aSignalThatDoesNotEndAUsageLimitKeepsItsFlag(kind: AgentJournalEventKind) {
        let limit = [event(1, .turnStarted), event(2, .childSpawned, request: "h"),
                     event(3, .errorReported, detail: "rate_limit")]
        #expect(phase(after: limit) == .error && usageLimit(after: limit), "control: the limit is flagged")
        let after = limit + [event(4, kind, request: kind == .childCompleted ? "h" : nil)]
        #expect(phase(after: after) == .error, "\(kind) ended the error")
        #expect(usageLimit(after: after), "\(kind) dropped the usage limit while the error stands")
    }

    @Test func aServerErrorThatFollowsIsNotAUsageLimit() {
        let after = [event(1, .turnStarted), event(2, .childSpawned, request: "h"),
                     event(3, .errorReported, detail: "rate_limit"), event(4, .errorReported, detail: "server_error")]
        #expect(phase(after: after) == .error)
        #expect(!usageLimit(after: after), "a later typed error replaces the limit")
    }
}
