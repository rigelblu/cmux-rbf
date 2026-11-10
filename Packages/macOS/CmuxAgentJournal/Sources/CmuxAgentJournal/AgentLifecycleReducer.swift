/// Deterministic fold from semantic agent events to lifecycle state.
///
/// Determinism contract (unit-tested): the fold's result is a pure function
/// of the *set* of events, independent of delivery order or re-delivery —
/// each session keeps only its newest event by journal sequence, duplicates
/// and stale arrivals are dropped, and the surface-level phase is the
/// newest live session's (cm-128.6).
///
/// ```swift
/// var state = AgentLifecycleReducerState()
/// let reducer = AgentLifecycleReducer()
/// for event in events { reducer.apply(event, to: &state) }
/// let snapshot = state.snapshot()
/// ```
public struct AgentLifecycleReducer: Sendable {
    /// Creates a reducer.
    public init() {}

    /// Folds one event into `state`.
    ///
    /// - Parameters:
    ///   - event: The committed journal event.
    ///   - state: The accumulated state to mutate.
    /// - Returns: `true` when the event changed lifecycle state (as opposed
    ///   to being a duplicate, stale, diagnostic-only, or non-lifecycle
    ///   event).
    @discardableResult
    public func apply(
        _ event: AgentJournalEvent,
        to state: inout AgentLifecycleReducerState
    ) -> Bool {
        state.advanceHead(to: event.sequence)
        guard event.draft.unattributedReason == nil else {
            state.recordUnattributed(event)
            return false
        }
        guard let surfaceId = event.draft.surfaceId else {
            // Attribution requires a surface: a workspace-only target would
            // make the sidebar guess a pane. Preserve as a diagnostic.
            state.recordUnattributed(event)
            return false
        }
        guard !event.draft.isSubagent else {
            // Subagent sessions never drive the hosting pane's badge.
            return false
        }
        let agentKey = event.agentKey
        let sessionKey = AgentLifecycleReducerState.sessionKey(for: event.draft)
        let previous = state.session(
            surfaceId: surfaceId,
            agentKey: agentKey,
            sessionKey: sessionKey
        )
        guard let transition = transition(for: event.draft, previous: previous) else {
            // Non-lifecycle kind: a pure observation. It deliberately does
            // not touch the session watermark, so a lifecycle event that
            // arrives after a higher-sequence observation still applies —
            // the fold stays a function of the highest-sequence
            // lifecycle-bearing event alone, independent of delivery order.
            return false
        }
        if let previous, event.sequence <= previous.lastSequence {
            // Duplicate or out-of-order stale arrival: the newest
            // lifecycle-bearing event by journal sequence already governs
            // this session.
            return false
        }
        if let previous, event.draft.kind != .stateChanged,
           event.draft.occurredAtMs < previous.lastOccurredAtMs {
            // A raw lifecycle event that happened before the session's newest
            // applied event is a late arrival, not a transition. An explicit
            // phase assertion is exempt: corrections restore a known-good
            // phase by journal order, so clock skew between the producer and
            // the app cannot strand a session behind a skewed timestamp.
            return false
        }
        let next = AgentSessionLifecycleState(
            phase: transition.phase,
            ended: transition.ended,
            lastSequence: event.sequence,
            lastOccurredAtMs: max(previous?.lastOccurredAtMs ?? 0, event.draft.occurredAtMs),
            // A signal that leaves an error standing (a helper's stop, an idle observation) keeps the usage limit it
            // already had; only a new `errorReported` decides it afresh. (cm-128.5, whole-diff review F4)
            usageLimit: transition.phase == .error && (Self.isUsageLimit(event.draft)
                || (event.draft.kind != .errorReported && previous?.phase == .error && previous?.usageLimit == true))
        )
        let combinedBefore = state.combinedPhase(surfaceId: surfaceId, agentKey: agentKey)
        state.updateSession(
            surfaceId: surfaceId,
            agentKey: agentKey,
            sessionKey: sessionKey,
            state: next
        )
        let combinedAfter = state.combinedPhase(surfaceId: surfaceId, agentKey: agentKey)
        return combinedBefore != combinedAfter
    }

    /// A typed usage limit (cm-128.5, Tom, grill Q31): the key is source, native event and `detail` together, never the
    /// `detail` string alone, since the generic path writes free text into it for every `errorReported`.
    /// Two producers write such a `detail`: Claude's `StopFailure` of type `rate_limit`, and Codex's `Stop` hook or
    /// `task_complete` monitor carrying `codex_error_info == "usage_limit_exceeded"`.
    static func isUsageLimit(_ draft: AgentJournalEventDraft) -> Bool {
        guard draft.kind == .errorReported else { return false }
        switch (draft.source, draft.nativeEvent, draft.detail) {
        case ("claude", "StopFailure"?, "rate_limit"?): return true
        case ("codex", "Stop"?, "usage_limit_exceeded"?), ("codex", "task_complete"?, "usage_limit_exceeded"?): return true
        default: return false
        }
    }

    private func transition(
        for draft: AgentJournalEventDraft,
        previous: AgentSessionLifecycleState?
    ) -> (phase: AgentLifecyclePhase, ended: Bool)? {
        switch draft.kind {
        case .sessionStarted:
            return (.unknown, false)
        case .turnStarted, .attentionResolved:
            return (.running, false)
        case .turnCompleted, .idleObserved:
            return (draft.pendingWork ? .running : .idle, false)
        case .approvalRequested, .questionRequested, .planReviewRequested:
            return (.needsInput, false)
        case .errorReported:
            return (.error, false)
        case .sessionEnded:
            return (previous?.phase ?? .unknown, true)
        case .stateChanged:
            // Only an explicit phase assertion moves state; plain
            // state-changed events are observations.
            guard let declared = draft.declaredPhase else { return nil }
            return (declared, previous?.ended ?? false)
        case .childSpawned, .childCompleted, .childFailed, .messagePublished:
            return nil
        }
    }
}
