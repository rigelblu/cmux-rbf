internal import Foundation
internal import CryptoKit

/// Reconciles all providers' notification candidates on the journal's ordered consumer.
///
/// The session identity survives surface moves. Pending completions never reserve
/// an attention identity. Blocking requests are independent of completion identity,
/// so duplicate stops cannot swallow a later real approval. Replay observes state
/// through this same fold, but the caller never dispatches replay effects.
public struct AgentNotificationReconciler: Sendable {
    /// How long after a Feed-backed wait is retired Claude's generic permission reminder still counts as its echo. (cm-128.1)
    private static let lateReminderWindowMs: Int64 = 10_000
    /// Claude native events the Feed turns into a wait of its own. (cm-128.1)
    private static let feedAttentionNativeEvents: Set<String> = ["PermissionRequest", "AskUserQuestion", "ExitPlanMode"]
    /// Claude's form-raising `notification_type` values, and the ones that say a form was answered. (cm-128.5)
    private static let formTypes: Set<String> = ["elicitation_dialog", "elicitation_url_dialog"]
    private static let answeredFormTypes: Set<String> = ["elicitation_response", "elicitation_complete"]

    /// Whether a `detail` is on the typed path: it carries the `notification-type:` marker the CLI writes for a typed
    /// notification, or it is one of the four bare elicitation names cmux journaled before the marker, so a replayed
    /// older journal keeps cm-128.5's guard. No native-event condition: grok's payloads are camelCase. (#cm-124.5)
    private static func isTypedPath(detail: String?) -> Bool {
        guard let detail else { return false }
        return AgentNotificationTypeMarker.type(inDetail: detail) != nil
            || formTypes.contains(detail) || answeredFormTypes.contains(detail)
    }

    /// The newest accepted owner for one surface and agent pair.
    private struct SessionBoundary: Sendable {
        let sessionKey: String
        let sequence: Int64
    }

    private struct Session: Sendable {
        var occurredAtMs: Int64 = -1
        var sequence: Int64 = 0
        var surfaceID: String?
        var agentKey: String?
        /// Surfaces this session has intentionally left. A late event from one
        /// of these panes cannot move the session back without a fresh
        /// SessionStart ownership boundary.
        var retiredSurfaceIDs: Set<String> = []
        var superseded = false
        var turn: String = "initial"
        var nativeTurn: String?
        var seenTurns: Set<String> = []
        var phase: AgentLifecyclePhase = .unknown {
            didSet {
                // A hand can suspend watching; a settled or failed phase ends it. (#cm-128.3)
                if phase != .running && phase != .needsInput { watching = false }
            }
        }
        var ended = false
        var attentionEpoch: Int64 = 0
        var children: Set<String> = []
        var finishedChildren: Set<String> = []
        var rootStopped = false
        // cmux-rbf: the root finished watching background work, with no live child. (#cm-128.3)
        var watching = false
        var pendingCompletion: AgentJournalEvent?
        var delivered: [String: String] = [:]
        var deliveredSurfaceIDs: [String: String] = [:]
        // Blocking requests, separate from error and completion history.
        var attentionIdentities: Set<String> = []
        var attentionRequestIDs: [String: String] = [:]
        /// The raising event's `detail` per attention identity: an answered form may retire only a form's wait. (cm-128.5)
        var attentionTypes: [String: String] = [:]
        var completionIdentity: String?
        /// The settled turn reopened (a continuation without a new prompt)
        /// after its completion notified. Its next Stop reuses that completion
        /// identity and is deduplicated, so its idle reminder is the only signal
        /// left and must not be treated as repeating the already-read completion.
        var reopenedSinceCompletion = false
        var starts: Set<String> = []
        var resolvedRequests: Set<String> = []
        var completionTurns: [String: String] = [:]
        /// The newest Feed-backed wait of this Claude session, for recognising its late reminder. (cm-128.1)
        var latestFeedAttention: (identity: String, occurredAtMs: Int64)?

        /// The agent continues after the user's decision: a settled turn is live again.
        mutating func resumeWork() {
            rootStopped = false
            pendingCompletion = nil
            watching = false
            phase = .running
            if completionIdentity != nil { reopenedSinceCompletion = true }
        }

        /// Retires one pending blocking request, returning its producer dismissal handle.
        mutating func retireAttention(_ identity: String) -> String? {
            attentionIdentities.remove(identity)
            attentionTypes.removeValue(forKey: identity)
            if let request = attentionRequestIDs.removeValue(forKey: identity) { resolvedRequests.insert(request) }
            return delivered.removeValue(forKey: identity)
        }
    }
    private var sessions: [String: Session] = [:]
    /// Historical sessions are indexed only while they can receive events.
    /// Superseded, ended, and moved sessions are removed to keep boundaries
    /// cheap even when the journal contains a long history.
    private var sessionKeysBySurfaceAndAgent: [String: Set<String>] = [:]
    private var sessionBoundaries: [String: SessionBoundary] = [:]

    /// Creates an empty reconciler, suitable for live ingestion or journal replay.
    public init() {}

    /// Returns the open requests and native turn of one provider session. (cm-128.1)
    /// - Parameters:
    ///   - source: Stable producer slug, such as `claude`.
    ///   - sessionId: The provider's native session identity.
    /// - Returns: Sorted request IDs, the single id-less request's native turn,
    ///   the session's native turn, and the total count. The count distinguishes
    ///   an id-less request with a nil native turn from no open request.
    public func openRequests(source: String, sessionId: String) -> (
        identified: [String], unidentifiedTurn: String?, nativeTurn: String?, count: Int
    ) {
        guard let session = sessions[Self.key([source, sessionId])] else {
            return ([], nil, nil, 0)
        }
        let unidentifiedCount = session.attentionIdentities.count - session.attentionRequestIDs.count
        return (
            session.attentionRequestIDs.values.sorted(),
            unidentifiedCount == 1 ? session.nativeTurn : nil,
            session.nativeTurn,
            session.attentionIdentities.count
        )
    }

    /// Observes one committed semantic event and classifies its candidate.
    /// - Parameter event: A journal event with causal evidence from its adapter.
    /// - Returns: An admission candidate or a diagnostic explaining suppression.
    public mutating func apply(_ event: AgentJournalEvent) -> AgentNotificationDecision {
        let draft = event.draft
        guard draft.unattributedReason == nil, draft.surfaceId != nil,
              let sessionID = draft.sessionId, !sessionID.isEmpty else {
            return .init(.unattributed)
        }
        guard !draft.isSubagent else { return .init(.subagent) }
        let sessionKey = Self.key([draft.source, sessionID])
        let boundaryKey = Self.surfaceAgentKey(surfaceID: draft.surfaceId!, agentKey: draft.agentKey)
        if let boundary = sessionBoundaries[boundaryKey], boundary.sessionKey != sessionKey {
            // The lifecycle reducer's per-surface boundary is the authority:
            // an older session cannot invalidate a newer owner's receipts.
            if draft.kind != .sessionStarted || event.sequence <= boundary.sequence {
                return .init(.stale)
            }
        }
        if draft.kind == .sessionStarted,
           let existing = sessions[sessionKey],
           event.sequence <= existing.sequence
                || draft.occurredAtMs < existing.occurredAtMs {
            return .init(.stale)
        }
        if draft.kind == .sessionStarted,
           sessions[sessionKey]?.superseded == true {
            // Session boundaries are one-way. A late start from a retired
            // identity must not make it current again or invalidate the
            // receipts of the replacement owner.
            return .init(.stale)
        }
        var boundaryInvalidations: [String] = []
        if draft.kind == .sessionStarted, draft.sessionStartOwnsSurface {
            // A new session boundary supersedes every older session that was
            // attached to this pane. Release their delivered notifications
            // through the same correlation-key path as attention resolution.
            let indexedKeys = sessionKeysBySurfaceAndAgent[boundaryKey, default: []]
            for key in indexedKeys where key != sessionKey {
                guard var candidate = sessions[key] else { continue }
                boundaryInvalidations.append(contentsOf: candidate.delivered.values)
                candidate.delivered.removeAll()
                candidate.deliveredSurfaceIDs.removeAll()
                candidate.attentionIdentities.removeAll()
                candidate.attentionRequestIDs.removeAll()
                candidate.pendingCompletion = nil
                candidate.ended = true
                candidate.superseded = true
                sessions[key] = candidate
                sessionKeysBySurfaceAndAgent[boundaryKey]?.remove(key)
            }
        }
        var session = sessions[sessionKey] ?? Session()
        let originalSessionBeforeMove = session
        if session.superseded && draft.kind != .sessionStarted {
            return .init(.stale, invalidatedCorrelationKeys: boundaryInvalidations)
        }
        if draft.kind != .sessionStarted,
           let currentSurfaceID = session.surfaceID,
           currentSurfaceID != draft.surfaceId,
           session.retiredSurfaceIDs.contains(draft.surfaceId!) {
            // A session move is one-way until the provider emits a fresh
            // SessionStart. Do not let a delayed hook from the old pane revive
            // its retired error, status, or notification state.
            return .init(.stale, invalidatedCorrelationKeys: boundaryInvalidations)
        }
        if let previousSurfaceID = session.surfaceID, previousSurfaceID != draft.surfaceId {
            // Correlations are pane-scoped even though the semantic session
            // identity survives a move. Retire receipts on the old pane while
            // their originating surface is still known.
            for identity in Array(session.delivered.keys)
                where session.deliveredSurfaceIDs[identity] == previousSurfaceID {
                if let correlation = session.delivered.removeValue(forKey: identity) {
                    boundaryInvalidations.append(correlation)
                }
                session.deliveredSurfaceIDs.removeValue(forKey: identity)
            }
        }
        if draft.kind == .sessionStarted, sessions[sessionKey] != nil {
            // A reused native session id still marks a new authoritative
            // boundary after restart, /clear, or auto-resume. Retire every
            // receipt from the prior turn and reset its lifecycle projection
            // before later hooks can reuse the old StopFailure state.
            boundaryInvalidations.append(contentsOf: session.delivered.values)
            let seenTurns = session.seenTurns
            let retiredSurfaceIDs = session.retiredSurfaceIDs
            let previousSurfaceID = session.surfaceID
            // cmux-rbf: a SessionStart for a live session that is running, watching background work or settled keeps that
            // projection; only an error or a hand is reset, as upstream's #18970 retires them. (#cm-128.3, #cm-142.1)
            let carriedPhase: AgentLifecyclePhase? = !session.ended && (session.phase == .running || session.phase == .idle)
                ? session.phase : nil
            let carriedWatching = session.watching
            let carriedRootStopped = session.rootStopped
            session = Session()
            if let carriedPhase { // (#cm-128.3)
                session.phase = carriedPhase
                session.watching = carriedWatching
                session.rootStopped = carriedRootStopped
            }
            session.surfaceID = draft.surfaceId
            session.agentKey = draft.agentKey
            session.retiredSurfaceIDs = retiredSurfaceIDs
            if let previousSurfaceID, previousSurfaceID != draft.surfaceId {
                session.retiredSurfaceIDs.insert(previousSurfaceID)
            }
            session.retiredSurfaceIDs.remove(draft.surfaceId!)
            // Keep the old turn watermark so a late completion from the
            // superseded turn remains stale after the recovery reset.
            session.seenTurns = seenTurns
        }
        let movedFromPreviousSurface = session.surfaceID != nil && session.surfaceID != draft.surfaceId
        if movedFromPreviousSurface,
           let previousSurfaceID = session.surfaceID {
            session.retiredSurfaceIDs.insert(previousSurfaceID)
            session.retiredSurfaceIDs.remove(draft.surfaceId!)
        }
        session.surfaceID = draft.surfaceId
        session.agentKey = draft.agentKey

        /// Commits a pane move even when the event is later suppressed by an
        /// identity or freshness guard, preserving origin invalidations and
        /// the move watermark together.
        func finalizeMovedDecision(_ decision: AgentNotificationDecision) -> AgentNotificationDecision {
            guard movedFromPreviousSurface else { return decision }
            let moveIsFresh = draft.occurredAtMs > originalSessionBeforeMove.occurredAtMs
                || (draft.occurredAtMs == originalSessionBeforeMove.occurredAtMs
                    && event.sequence > originalSessionBeforeMove.sequence)
            guard moveIsFresh else {
                session = originalSessionBeforeMove
                return decision
            }
            session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
            session.sequence = max(session.sequence, event.sequence)
            storeSession(session, for: sessionKey, indexKey: boundaryKey)
            guard !boundaryInvalidations.isEmpty else { return decision }
            return .init(
                decision.disposition,
                identity: decision.identity,
                invalidatedCorrelationKeys: boundaryInvalidations + decision.invalidatedCorrelationKeys,
                notificationEvent: decision.notificationEvent,
                projectsLifecycle: decision.projectsLifecycle,
                remindedCompletion: decision.remindedCompletion
            )
        }
        let context = draft.attention
        if draft.kind == .stateChanged, draft.declaredPhase == nil {
            // cmux-rbf: the first time ever an agent sends a type no row maps, its banner is accepted once. The CLI
            // marks such an observation `notification-type:<type>`; the marker alone decides, and the receipt
            // (`claimNotification`) makes it once per agent and type across restarts. No hand rises. (#cm-124.5)
            let decision: AgentNotificationDecision
            if context?.notification != nil, let type = AgentNotificationTypeMarker.type(inDetail: draft.detail) {
                decision = .init(.accepted, identity: Self.key(["unmapped-notification", draft.source, type]),
                                 projectsLifecycle: false)
            } else {
                decision = .init(.observation)
            }
            if !movedFromPreviousSurface {
                storeSession(session, for: sessionKey, indexKey: boundaryKey)
                return decision
            }
            return finalizeMovedDecision(decision)
        }
        let incomingTurn = context?.turnIdentity
        if [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind),
           let request = context?.requestIdentity, session.resolvedRequests.contains(request) {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        let isResolution = draft.kind == .attentionResolved
            || draft.kind == .childCompleted || draft.kind == .childFailed
        var requestInvalidations: [String] = boundaryInvalidations
        if draft.kind == .attentionResolved, context?.requestIdentity == nil,
           Self.isTypedPath(detail: draft.detail) {
            // cm-128.5: an id-less resolve retires the session's one open wait whatever raised it, so a form's answer
            // could retire a permission waiting behind it. It retires only a wait a form raised; any other is an observation.
            // cm-124.5: "a form raised" is now "a typed question raised": any wait raised on the typed path. Every other
            // id-less resolve (Hermes's `approval-response`, Amp's `running`) keeps today's rule. (#cm-124.5)
            guard session.attentionIdentities.count == 1, let identity = session.attentionIdentities.first,
                  session.attentionTypes[identity] != nil else {
                return finalizeMovedDecision(.init(.observation, projectsLifecycle: false))
            }
        }
        if isResolution {
            // Claude also sends unmatched SubagentStop events after a root Stop. (#cm-128.3)
            if draft.source == "claude", draft.kind == .childCompleted || draft.kind == .childFailed {
                guard let child = context?.requestIdentity, session.children.contains(child) else {
                    return finalizeMovedDecision(.init(.observation, projectsLifecycle: false))
                }
            }
            // A work observation is not a resolution. Only this explicit semantic
            // event can retire an immutable request/child ID behind a newer watermark.
            // A late reply still retires its own request. Only a fresh running
            // tool event may reopen a settled turn.
            let fresh = draft.occurredAtMs > session.occurredAtMs
                || (draft.occurredAtMs == session.occurredAtMs && event.sequence > session.sequence)
            let isIdentitylessToolStart = incomingTurn == nil
                && draft.nativeEvent?.caseInsensitiveCompare("PreToolUse") == .orderedSame
            let incomingTurn = context?.turnIdentity
            let isNewTurn = incomingTurn != nil
                && session.nativeTurn != nil
                && incomingTurn != session.nativeTurn
            if draft.kind == .attentionResolved, draft.declaredPhase == .running, fresh,
               !session.ended,
               draft.pendingWork
                || (isNewTurn && incomingTurn.map { !session.seenTurns.contains($0) } == true)
                || (isIdentitylessToolStart && fresh) {
                // A tool completion is progress, including a continuation
                // that starts without UserPromptSubmit. Reopen only fresh
                // activity with a new turn identity; an older or same-turn
                // result cannot resurrect a settled pane.
                if let incomingTurn, isNewTurn {
                    session.turn = incomingTurn
                    session.nativeTurn = incomingTurn
                }
                session.resumeWork()
            }
            if let request = context?.requestIdentity {
                if draft.kind == .attentionResolved {
                    let wasResolved = session.resolvedRequests.contains(request)
                    session.resolvedRequests.insert(request)
                    let identity = Self.key([sessionKey, Self.key(["attention", request])])
                    if let key = session.retireAttention(identity) { requestInvalidations.append(key) }
                    if draft.pendingWork && !wasResolved && fresh { session.resumeWork() }
                } else {
                    session.finishedChildren.insert(request)
                    session.children.remove(request)
                }
            } else if draft.kind == .attentionResolved, fresh,
                      context?.turnIdentity == session.nativeTurn,
                      session.attentionIdentities.count == 1,
                      let identity = session.attentionIdentities.first {
                // An identity-less reply answers only the one request pending on
                // its own turn. An ambiguous or older reply keeps the wait.
                if let key = session.retireAttention(identity) { requestInvalidations.append(key) }
                if draft.pendingWork { session.resumeWork() }
            }
            if !session.attentionIdentities.isEmpty {
                session.phase = .needsInput
            } else if draft.declaredPhase == .idle {
                // Only an idle declaration (a dismissed idle dialog) settles the
                // turn. Fresh tool activity explicitly reopens it below.
                session.phase = .idle
                session.rootStopped = true
            } else if session.rootStopped && session.children.isEmpty {
                session.phase = .idle
            } else if session.phase == .needsInput {
                session.phase = .running
            }
            session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
            session.sequence = max(session.sequence, event.sequence)
            let pending = session.phase == .idle && !session.ended ? session.pendingCompletion : nil
            if pending != nil { session.pendingCompletion = nil }
            storeSession(session, for: sessionKey, indexKey: boundaryKey)
            if let pending {
                var completion = pending.draft
                completion.occurredAtMs = session.occurredAtMs
                completion.pendingWork = false
                let released = AgentJournalEvent(sequence: session.sequence, committedAtMs: event.committedAtMs, draft: completion)
                let decision = apply(released)
                return .init(decision.disposition, identity: decision.identity,
                    invalidatedCorrelationKeys: requestInvalidations + decision.invalidatedCorrelationKeys,
                    notificationEvent: released, remindedCompletion: decision.remindedCompletion)
            }
            return .init(.observation, invalidatedCorrelationKeys: requestInvalidations)
        }
        let isAttention = [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind)
        if isAttention, let incomingTurn, let currentTurn = session.nativeTurn,
           incomingTurn != currentTurn, session.seenTurns.contains(incomingTurn) {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        if isAttention, context?.requestIdentity == nil, !session.attentionIdentities.isEmpty {
            // A generic permission reminder adds no new request identity. Do not
            // let it re-notify or advance the watermark past a real later request.
            guard context?.notification != nil else {
                return finalizeMovedDecision(.init(.observation, projectsLifecycle: false))
            }
            guard session.attentionIdentities.count == 1,
                  let identity = session.attentionIdentities.first else {
                return finalizeMovedDecision(.init(.observation, projectsLifecycle: false))
            }
            var reminder = draft
            reminder.attention?.notification?.correlationKey = session.delivered[identity]
            return finalizeMovedDecision(.init(.accepted, identity: identity,
                notificationEvent: AgentJournalEvent(sequence: event.sequence, committedAtMs: event.committedAtMs, draft: reminder),
                projectsLifecycle: false))
        }
        if draft.source == "claude", draft.kind == .approvalRequested,
           draft.nativeEvent == "Notification", context?.requestIdentity == nil,
           session.attentionIdentities.isEmpty,
           let latest = session.latestFeedAttention,
           draft.occurredAtMs >= latest.occurredAtMs,
           draft.occurredAtMs - latest.occurredAtMs < Self.lateReminderWindowMs {
            // cm-128.1: Claude's delayed permission reminder may arrive after the terminal
            // answer. A later prompt without Feed evidence must still open a wait.
            return finalizeMovedDecision(.init(.observation, projectsLifecycle: false))
        }
        let independentRequest = isAttention && context?.requestIdentity != nil && session.phase == .needsInput
        if !independentRequest && (draft.occurredAtMs < session.occurredAtMs
            || (draft.occurredAtMs == session.occurredAtMs && event.sequence < session.sequence)) {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        if draft.kind == .messagePublished {
            guard !session.ended else {
                session = originalSessionBeforeMove
                return .init(.stale)
            }
            guard context?.notification != nil else {
                return finalizeMovedDecision(.init(.observation))
            }
            let key = context?.requestIdentity ?? context?.eventIdentity ?? draft.eventId
            return finalizeMovedDecision(.init(
                .accepted,
                identity: Self.key([sessionKey, "message", key])
            ))
        }
        if (draft.kind == .turnCompleted || draft.kind == .idleObserved), let incomingTurn,
           let nativeTurn = session.nativeTurn, incomingTurn != nativeTurn {
            guard session.phase != .running, session.phase != .needsInput,
                  !session.seenTurns.contains(incomingTurn) else {
                session = originalSessionBeforeMove
                return .init(.stale)
            }
            session.turn = incomingTurn
            session.nativeTurn = incomingTurn
            session.completionIdentity = nil
            session.reopenedSinceCompletion = false
        }
        if draft.kind == .idleObserved {
            // cmux-rbf: an idle observation for the native turn settles it while that turn only watches background work,
            // so a watching turn can end. An active turn stays running, as upstream's #15887 keeps it. (#cm-128.3, #cm-142.1)
            let settlesWatchingTurn = session.phase == .running && session.watching
                && context?.turnIdentity != nil && context?.turnIdentity == session.nativeTurn
            guard !draft.pendingWork, session.attentionIdentities.isEmpty, session.children.isEmpty,
                  session.phase == .idle || session.phase == .unknown || settlesWatchingTurn, // (#cm-128.3)
                  !session.ended else {
                // Even a delayed idle observation commits a pane move so the
                // origin receipt invalidations cannot be lost on this early exit.
                return finalizeMovedDecision(.init(
                    .delayed,
                    projectsLifecycle: false
                ))
            }
            session.phase = .idle
            session.rootStopped = true
            session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
            session.sequence = max(session.sequence, event.sequence)
            storeSession(session, for: sessionKey, indexKey: boundaryKey)
            guard context?.notification != nil else {
                return .init(.observation, invalidatedCorrelationKeys: boundaryInvalidations)
            }
            // A structured idle reminder is a distinct presentation from the
            // completion that settled the turn. Keep the legacy completion
            // identity for generic idle observations, but admit one reminder
            // for the same settled turn so the banner can still be delivered
            // without reopening lifecycle attention.
            let identityKind = context?.notification?.category == "idle-reminder"
                ? "idle-reminder"
                : "completion"
            let identity: String
            if identityKind == "idle-reminder" {
                identity = Self.key([sessionKey, Self.key([
                    identityKind,
                    context?.turnIdentity ?? session.turn,
                    context?.requestIdentity ?? "",
                ])])
            } else {
                // Preserve the completion receipt shape for generic idle
                // observations and journal replay compatibility.
                identity = Self.key([sessionKey, Self.key([identityKind, context?.turnIdentity ?? session.turn])])
            }
            // The reminder repeats this turn's completion. Only the app knows
            // whether the user already read or dismissed it.
            let remindedCompletion = identityKind == "idle-reminder" && !session.reopenedSinceCompletion
                ? session.completionIdentity.flatMap { completion in
                    session.delivered[completion].map {
                        AgentNotificationDecision.RemindedCompletion(identity: completion, correlationKey: $0)
                    }
                }
                : nil
            session.delivered[identity] = context?.notification?.correlationKey ?? identity
            session.deliveredSurfaceIDs[identity] = draft.surfaceId
            if identityKind == "completion" {
                session.completionIdentity = identity
            }
            storeSession(session, for: sessionKey, indexKey: boundaryKey)
            return .init(
                .accepted,
                identity: identity,
                invalidatedCorrelationKeys: boundaryInvalidations,
                projectsLifecycle: context?.notification?.category != "idle-reminder",
                remindedCompletion: remindedCompletion
            )
        }
        if draft.kind == .turnStarted, let incomingTurn, incomingTurn == session.turn,
           session.phase == .needsInput || session.phase == .idle {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        if draft.kind == .turnStarted, let key = context?.eventIdentity,
           session.starts.contains(key) {
            session = originalSessionBeforeMove
            return .init(.stale)
        }
        if draft.kind == .turnCompleted, session.nativeTurn == nil, let incomingTurn {
            session.turn = incomingTurn
            session.nativeTurn = incomingTurn
        }
        if draft.kind == .turnCompleted, let key = context?.eventIdentity {
            if let boundTurn = session.completionTurns[key], boundTurn != session.turn {
                session = originalSessionBeforeMove
                return .init(.stale)
            }
            session.completionTurns[key] = session.turn
        }
        var invalidated: [String] = boundaryInvalidations
        if draft.kind == .turnStarted || draft.kind == .sessionEnded {
            invalidated.append(contentsOf: session.delivered.values)
            session.delivered.removeAll()
            session.deliveredSurfaceIDs.removeAll()
            session.attentionIdentities.removeAll()
            session.resolvedRequests.formUnion(session.attentionRequestIDs.values)
            session.attentionRequestIDs.removeAll()
            session.attentionTypes.removeAll()
            session.completionIdentity = nil
            session.reopenedSinceCompletion = false
            session.pendingCompletion = nil
        }
        let previousPhase = session.phase
        switch draft.kind {
        case .messagePublished, .attentionResolved, .idleObserved:
            return .init(.observation, invalidatedCorrelationKeys: invalidated)
        case .sessionStarted:
            if session.ended { session.phase = .unknown; session.nativeTurn = nil }
            session.ended = false
            session.superseded = false
            if draft.sessionStartOwnsSurface {
                sessionBoundaries[boundaryKey] = SessionBoundary(
                    sessionKey: sessionKey,
                    sequence: event.sequence
                )
            }
        case .turnStarted:
            session.rootStopped = false
            let wasWatching = session.watching
            session.watching = false
            if let key = context?.eventIdentity { session.starts.insert(key) }
            if incomingTurn != nil || context?.eventIdentity != nil || session.phase != .running || wasWatching {
                session.turn = incomingTurn ?? context?.eventIdentity ?? draft.eventId
                session.nativeTurn = incomingTurn
            }
            session.phase = .running
            session.ended = false
        case .turnCompleted:
            // A Claude Stop counts background helpers too: no pending work proves a lost child Stop is settled. (#cm-128.3)
            if draft.source == "claude", !draft.pendingWork { session.children.removeAll() }
            // Codex's pending-work signal is always its live-child count. (#cm-128.3)
            session.watching = draft.source != "codex" && draft.pendingWork && session.children.isEmpty
            session.rootStopped = !draft.pendingWork
            if !draft.pendingWork, !session.children.isEmpty, context?.notification != nil {
                session.pendingCompletion = event
            }
            if session.turn == "initial", let incomingTurn { session.turn = incomingTurn }
            let pending = draft.pendingWork || !session.children.isEmpty
            if !draft.pendingWork {
                for identity in Array(session.delivered.keys) where identity != session.completionIdentity {
                    if let key = session.delivered.removeValue(forKey: identity) { invalidated.append(key) }
                }
                session.attentionIdentities.removeAll()
                session.resolvedRequests.formUnion(session.attentionRequestIDs.values)
                session.attentionRequestIDs.removeAll()
                session.attentionTypes.removeAll()
            }
            session.phase = pending ? (session.attentionIdentities.isEmpty ? .running : .needsInput) : .idle
        case .approvalRequested, .questionRequested, .planReviewRequested:
            if let incomingTurn { session.turn = incomingTurn; session.nativeTurn = incomingTurn }
            if previousPhase != .needsInput { session.attentionEpoch = event.sequence }
            session.phase = .needsInput
        case .errorReported:
            session.phase = .error
        case .sessionEnded:
            session.ended = true
            session.watching = false
        case .stateChanged:
            if draft.declaredPhase == .running || draft.declaredPhase == .unknown { session.watching = false }
            if draft.declaredPhase == .running {
                let isNewTurn = incomingTurn != nil
                    && incomingTurn != session.nativeTurn
                    && incomingTurn.map { !session.seenTurns.contains($0) } == true
                let isFreshIdentitylessActivity = incomingTurn == nil
                    && draft.nativeEvent?.caseInsensitiveCompare("PreToolUse") == .orderedSame
                    && (draft.occurredAtMs > session.occurredAtMs
                        || (draft.occurredAtMs == session.occurredAtMs && event.sequence > session.sequence))
                // A tool event without a turn identity is ambiguous after a
                // completion. Reopen only when its event timestamp/sequence is
                // newer than the completion watermark; this admits promptless
                // continuations while a late older event remains stale.
                guard session.phase != .idle || isNewTurn || isFreshIdentitylessActivity else { break }
                if isNewTurn, let incomingTurn {
                    session.turn = incomingTurn
                    session.nativeTurn = incomingTurn
                }
                session.rootStopped = false
                session.pendingCompletion = nil
                if session.completionIdentity != nil { session.reopenedSinceCompletion = true }
            }
            if let phase = draft.declaredPhase {
                session.phase = phase == .running && !session.attentionIdentities.isEmpty ? .needsInput : phase
            }
        case .childSpawned:
            if let child = context?.requestIdentity, !session.finishedChildren.contains(child) {
                session.children.insert(child)
                session.watching = false
                if session.phase == .idle || session.phase == .unknown { session.phase = .running }
            }
        case .childCompleted, .childFailed:
            if let child = context?.requestIdentity { session.children.remove(child) }
        }
        if let turn = session.nativeTurn { session.seenTurns.insert(turn) }
        session.occurredAtMs = max(session.occurredAtMs, draft.occurredAtMs)
        session.sequence = max(session.sequence, event.sequence)
        storeSession(session, for: sessionKey, indexKey: boundaryKey)
        guard context?.notification != nil else { return .init(.observation, invalidatedCorrelationKeys: invalidated) }
        guard !session.ended else { return .init(.stale) }
        let boundary: String
        switch draft.kind {
        case .turnCompleted:
            guard session.phase == .idle || (session.phase == .running && session.watching) else { return .init(.delayed) }
            boundary = Self.key(["completion", incomingTurn ?? session.turn])
        case .approvalRequested, .questionRequested, .planReviewRequested:
            // A real blocking request is never gated by background work.
            boundary = Self.key(["attention", context?.requestIdentity
                ?? "\(session.turn):\(session.attentionEpoch)"])
        case .errorReported:
            boundary = Self.key(["error", context?.eventIdentity ?? session.turn])
        default:
            return .init(.observation, invalidatedCorrelationKeys: invalidated)
        }
        let identity = Self.key([sessionKey, boundary])
        session.delivered[identity] = context?.notification?.correlationKey ?? identity
        session.deliveredSurfaceIDs[identity] = draft.surfaceId
        if [.approvalRequested, .questionRequested, .planReviewRequested].contains(draft.kind) {
            session.attentionIdentities.insert(identity)
            if let request = context?.requestIdentity { session.attentionRequestIDs[identity] = request }
            // cm-124.5: an entry only for a wait raised on the typed path, so the guard above can tell it. (#cm-124.5)
            if let detail = draft.detail, Self.isTypedPath(detail: detail) { session.attentionTypes[identity] = detail }
            // cm-128.1: remember the newest Feed-backed wait, so its late reminder is not mistaken for a new one.
            // cm-124.6: a row tool's wait has no Feed request, so its `tool-row:` marker stands in for one: Claude's late
            // permission reminder after a quick answer is the same echo cm-128 Q24 ignores. A built-in tool's bypass-mode
            // wait carries no marker and keeps today's rule. (#cm-124.6)
            let isFeedEvidence = draft.nativeEvent.map(Self.feedAttentionNativeEvents.contains) == true
                || AgentToolRowMarker.tool(inDetail: draft.detail) != nil
            if draft.source == "claude", isFeedEvidence,
               draft.occurredAtMs >= (session.latestFeedAttention?.occurredAtMs ?? -1) {
                session.latestFeedAttention = (identity, draft.occurredAtMs)
            }
        }
        if draft.kind == .turnCompleted {
            // Re-asserting the same identity after a reopen keeps the flag: that
            // Stop's notification is deduplicated against the read completion.
            if session.completionIdentity != identity { session.reopenedSinceCompletion = false }
            session.completionIdentity = identity
        }
        storeSession(session, for: sessionKey, indexKey: boundaryKey)
        return .init(.accepted, identity: identity, invalidatedCorrelationKeys: invalidated)
    }

    /// Projects the reconciled phase back into the shared lifecycle fold.
    /// - Parameter event: The event just observed through `apply`.
    /// - Returns: A lifecycle assertion using the same causal state as admission.
    public func lifecycleEvent(_ event: AgentJournalEvent) -> AgentJournalEvent {
        var draft = event.draft
        guard let sessionID = draft.sessionId,
              let session = sessions[Self.key([draft.source, sessionID])] else { return event }
        let phase: AgentLifecyclePhase = session.phase == .running && session.watching ? .monitoring : session.phase
        switch draft.kind {
        case .sessionStarted where session.phase != .unknown:
            // cmux-rbf: the start keeps its kind, so the reducer still records upstream's session boundary, and declares the
            // phase it carries. (#cm-128.3, #cm-142.1)
            draft.declaredPhase = phase
        case .turnCompleted:
            if phase == .needsInput || phase == .monitoring {
                draft.kind = .stateChanged
                draft.declaredPhase = phase
            } else {
                draft.pendingWork = session.phase == .running
            }
        case .stateChanged where draft.declaredPhase != nil:
            draft.declaredPhase = phase
        case .idleObserved, .attentionResolved, .childSpawned, .childCompleted, .childFailed:
            draft.occurredAtMs = max(draft.occurredAtMs, session.occurredAtMs)
            draft.kind = .stateChanged
            draft.declaredPhase = phase
        default:
            break
        }
        return AgentJournalEvent(sequence: event.sequence, committedAtMs: event.committedAtMs, draft: draft)
    }

    private static func key(_ components: [String]) -> String {
        let framed = components.map { "\($0.utf8.count):\($0)" }.joined()
        let digits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64)
        for byte in SHA256.hash(data: Data(framed.utf8)) {
            bytes.append(digits[Int(byte >> 4)])
            bytes.append(digits[Int(byte & 15)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Names the bounded index and lifecycle boundary for one pane/agent pair.
    private static func surfaceAgentKey(surfaceID: String, agentKey: String) -> String {
        key([surfaceID, agentKey])
    }

    /// Persists a session and keeps the bounded surface index in sync.
    private mutating func storeSession(_ session: Session, for sessionKey: String, indexKey: String) {
        if let previous = sessions[sessionKey],
           let previousSurfaceID = previous.surfaceID,
           let previousAgentKey = previous.agentKey {
            let previousKey = Self.surfaceAgentKey(
                surfaceID: previousSurfaceID,
                agentKey: previousAgentKey
            )
            if previousKey != indexKey {
                sessionKeysBySurfaceAndAgent[previousKey]?.remove(sessionKey)
                if sessionKeysBySurfaceAndAgent[previousKey]?.isEmpty == true {
                    sessionKeysBySurfaceAndAgent.removeValue(forKey: previousKey)
                }
            }
        }
        if session.ended {
            sessionKeysBySurfaceAndAgent[indexKey]?.remove(sessionKey)
            if sessionKeysBySurfaceAndAgent[indexKey]?.isEmpty == true {
                sessionKeysBySurfaceAndAgent.removeValue(forKey: indexKey)
            }
        } else {
            sessionKeysBySurfaceAndAgent[indexKey, default: []].insert(sessionKey)
        }
        sessions[sessionKey] = session
    }
}
