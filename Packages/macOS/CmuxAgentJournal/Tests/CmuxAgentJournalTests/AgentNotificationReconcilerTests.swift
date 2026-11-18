import Foundation
import Testing
@testable import CmuxAgentJournal

struct AgentNotificationReconcilerTests {
    private let workspace = UUID().uuidString
    private let surface = UUID().uuidString

    private func event(_ sequence: Int64, _ kind: AgentJournalEventKind, source: String,
                       turn: String? = "turn-1", request: String? = nil, pending: Bool = false,
                       notify: Bool = true, occurredAt: Int64? = nil, nativeID: String? = nil,
                       surfaceID: String? = nil, nativeEvent: String? = nil) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 1000 + sequence,
            draft: AgentJournalEventDraft(eventId: "event-\(sequence)", kind: kind,
                occurredAtMs: occurredAt ?? sequence, source: source, agentKey: source,
                sessionId: "session", workspaceId: workspace, surfaceId: surfaceID ?? surface,
                pendingWork: pending, nativeEvent: nativeEvent, attention: AgentAttentionContext(eventIdentity: nativeID,
                    turnIdentity: turn, requestIdentity: request,
                    notification: notify ? AgentJournalNotification(title: "Agent", subtitle: "",
                        body: "Ready", category: kind == .turnCompleted ? "turn-complete" : "needs-permission") : nil)))
    }

    @Test(arguments: ["claude", "codex"])
    func duplicateAndReadReplayReserveOneDelivery(source: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try AgentJournalStore(databaseURL: url.appendingPathComponent("journal.sqlite"))
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let first = reconciler.apply(event(2, .turnCompleted, source: source))
        let duplicate = reconciler.apply(event(3, .turnCompleted, source: source))
        let identity = try #require(first.identity)
        #expect(first.disposition == .accepted)
        #expect(duplicate.identity == identity)
        #expect(try store.claimNotification(identity: identity))
        #expect(try !store.claimNotification(identity: identity))
        // Read/dismiss does not delete the receipt. Reopening represents an app restart.
        store.close()
        let reopened = try AgentJournalStore(databaseURL: url.appendingPathComponent("journal.sqlite"))
        defer { reopened.close() }
        #expect(try !reopened.claimNotification(identity: identity))
    }

    @Test(arguments: ["claude", "codex"])
    func pendingStopRespectsItsSourceWithoutSwallowingSettledCompletionOrApproval(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        #expect(reconciler.apply(event(2, .turnCompleted, source: source, pending: true)).disposition
            == (source == "codex" ? .delayed : .accepted))
        let wait = reconciler.apply(event(3, .approvalRequested, source: source, request: "approval", pending: true))
        #expect(wait.disposition == .accepted)
        let done = reconciler.apply(event(4, .turnCompleted, source: source))
        #expect(done.disposition == .accepted)
        #expect(wait.identity != done.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func lateStopCannotSettleContinuingTurn(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let first = reconciler.apply(event(2, .turnCompleted, source: source))
        let continuing = reconciler.apply(event(3, .turnStarted, source: source, turn: "turn-2", notify: false))
        let firstIdentity = try #require(first.identity)
        #expect(continuing.invalidatedCorrelationKeys == [firstIdentity])
        #expect(reconciler.apply(event(4, .turnCompleted, source: source)).disposition == .stale)
        let next = reconciler.apply(event(5, .questionRequested, source: source, turn: "turn-2", request: "question"))
        #expect(next.disposition == .accepted)
        #expect(next.identity != first.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func outOfOrderStopPreservesRealLaterWait(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let wait = reconciler.apply(event(2, .approvalRequested, source: source, request: "r1", occurredAt: 30))
        #expect(reconciler.apply(event(3, .turnCompleted, source: source, occurredAt: 20)).disposition == .stale)
        let next = reconciler.apply(event(4, .approvalRequested, source: source, request: "r2", occurredAt: 40))
        #expect(next.disposition == .accepted)
        #expect(next.identity != wait.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func movedAndResumedSessionKeepsSemanticIdentity(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let first = reconciler.apply(event(2, .approvalRequested, source: source, request: "r1"))
        let moved = reconciler.apply(event(3, .approvalRequested, source: source, request: "r1", surfaceID: UUID().uuidString))
        #expect(first.identity == moved.identity)
        let later = reconciler.apply(event(4, .approvalRequested, source: source, request: "r2", surfaceID: UUID().uuidString))
        #expect(later.identity != first.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func duplicateStartCannotEraseApprovalOrRearmCompletion(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false, nativeID: "prompt-1"))
        let first = reconciler.apply(event(2, .approvalRequested, source: source, request: "r1"))
        let duplicate = reconciler.apply(event(3, .turnStarted, source: source, notify: false, nativeID: "prompt-1"))
        #expect(duplicate.disposition == .stale)
        #expect(duplicate.invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.apply(event(4, .approvalRequested, source: source, request: "r1")).identity == first.identity)
    }

    @Test func contextPersistsAndIdempotentAppendRejectsChangedEvidence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = try AgentJournalStore(databaseURL: url.appendingPathComponent("journal.sqlite"))
        defer { store.close() }
        let draft = event(1, .approvalRequested, source: "claude", request: "request").draft
        _ = try store.append(draft)
        #expect(try store.events(afterSequence: 0, limit: 10).first?.draft == draft)
        #expect(try store.append(draft).replayed)
        var conflict = draft
        conflict.attention?.requestIdentity = "different"
        #expect(throws: AgentJournalStoreError.self) { try store.append(conflict) }
    }
    @Test(arguments: ["claude", "codex"])
    func resolvedRequestCannotReplayWhileNewApprovalRemainsDeliverable(source: String) {
        var reconciler = AgentNotificationReconciler()
        var resolved = event(1, .attentionResolved, source: source, request: "resolved", notify: false).draft
        resolved.declaredPhase = .running
        _ = reconciler.apply(AgentJournalEvent(sequence: 1, committedAtMs: 1, draft: resolved))
        #expect(reconciler.apply(event(2, .approvalRequested, source: source, request: "resolved")).disposition == .stale)
        #expect(reconciler.apply(event(3, .approvalRequested, source: source, request: "new")).disposition == .accepted)
    }

    @Test(arguments: ["claude", "codex"])
    func detachedTurnStartCannotClearItsAlreadyObservedApproval(source: String) {
        var reconciler = AgentNotificationReconciler()
        let approval = reconciler.apply(event(1, .approvalRequested, source: source, request: "r1"))
        let lateStart = reconciler.apply(event(2, .turnStarted, source: source, notify: false))
        #expect(lateStart.disposition == .stale)
        #expect(lateStart.invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.apply(event(3, .approvalRequested, source: source, request: "r1")).identity == approval.identity)
    }
    @Test(arguments: ["claude", "codex"])
    func observationsDoNotInvalidateCompletion(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        _ = reconciler.apply(event(3, .stateChanged, source: source, notify: false, occurredAt: 30))
        #expect(reconciler.apply(event(2, .turnCompleted, source: source, occurredAt: 20)).disposition == .accepted)
    }

    @Test(arguments: ["claude", "codex"])
    func explicitMessageIsIdempotentAndDoesNotSettleTheTurn(source: String) {
        var reconciler = AgentNotificationReconciler()
        let start = event(1, .turnStarted, source: source, notify: false)
        _ = reconciler.apply(start)
        let message = reconciler.apply(event(2, .messagePublished, source: source, request: "push"))
        #expect(message.disposition == .accepted)
        #expect(reconciler.apply(event(3, .messagePublished, source: source, request: "push")).identity == message.identity)
        #expect(reconciler.apply(event(4, .turnCompleted, source: source)).identity != message.identity)
    }
    @Test(arguments: ["claude", "codex"])
    func workObservationDoesNotResolveARealApproval(source: String) {
        var reconciler = AgentNotificationReconciler()
        var work = event(1, .stateChanged, source: source, request: "tool", notify: false).draft
        work.declaredPhase = .running
        _ = reconciler.apply(AgentJournalEvent(sequence: 1, committedAtMs: 1, draft: work))
        let approval = reconciler.apply(event(2, .approvalRequested, source: source, request: "tool", occurredAt: 30))
        #expect(approval.disposition == .accepted)
        work.occurredAtMs = 20
        let stale = reconciler.apply(AgentJournalEvent(sequence: 3, committedAtMs: 3, draft: work))
        #expect(stale.disposition == .stale)
        #expect(stale.invalidatedCorrelationKeys.isEmpty)
    }

    @Test(arguments: ["claude", "codex"])
    func lateResolutionRetiresOnlyItsOwnImmutableRequest(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        let old = reconciler.apply(event(1, .approvalRequested, source: source, request: "old", occurredAt: 10))
        let newer = reconciler.apply(event(2, .approvalRequested, source: source, request: "new", occurredAt: 30))
        let resolved = reconciler.apply(event(3, .attentionResolved, source: source, request: "old", notify: false, occurredAt: 20))
        let oldIdentity = try #require(old.identity)
        let newerIdentity = try #require(newer.identity)
        #expect(resolved.invalidatedCorrelationKeys == [oldIdentity])
        #expect(!resolved.invalidatedCorrelationKeys.contains(newerIdentity))
        #expect(reconciler.apply(event(4, .approvalRequested, source: source, request: "old")).disposition == .stale)
    }

    // cmux-rbf: a Claude Stop without pending work proves its children settled. (#cm-128.3)
    @Test(arguments: ["codex"])
    func delayedParentCompletionIsReleasedByLastChildWithoutTimer(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        _ = reconciler.apply(event(2, .childSpawned, source: source, request: "child", notify: false))
        #expect(reconciler.apply(event(3, .turnCompleted, source: source)).disposition == .delayed)
        let end = event(4, .childCompleted, source: source, request: "child", notify: false, occurredAt: 2)
        let released = reconciler.apply(end)
        #expect(released.disposition == .accepted)
        #expect(released.notificationEvent?.kind == .turnCompleted)
        #expect(released.notificationEvent?.draft.attention?.notification?.body == "Ready")
        #expect(reconciler.lifecycleEvent(end).draft.declaredPhase == .idle)
        #expect(reconciler.apply(event(5, .childCompleted, source: source, request: "child", notify: false)).identity == nil)
        #expect(reconciler.apply(event(6, .turnCompleted, source: source)).identity == released.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func continueCancelsACompletionWaitingForChildren(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        _ = reconciler.apply(event(2, .childSpawned, source: source, request: "child", notify: false))
        _ = reconciler.apply(event(3, .turnCompleted, source: source))
        _ = reconciler.apply(event(4, .turnStarted, source: source, turn: "turn-2", notify: false))
        #expect(reconciler.apply(event(5, .childCompleted, source: source, request: "child", notify: false)).identity == nil)
    }

    @Test(arguments: ["claude", "codex"])
    func identityLessTurnsDoNotCollapseRealIdenticalSubmissions(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, turn: nil, notify: false))
        _ = reconciler.apply(event(2, .turnStarted, source: source, turn: nil, notify: false))
        let first = reconciler.apply(event(3, .turnCompleted, source: source, turn: nil))
        #expect(reconciler.apply(event(4, .turnCompleted, source: source, turn: nil)).identity == first.identity)
        _ = reconciler.apply(event(5, .turnStarted, source: source, turn: nil, notify: false))
        #expect(reconciler.apply(event(6, .turnCompleted, source: source, turn: nil)).identity != first.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func resumedCompletionWithAnUnseenTurnCanRecoverAMissedStart(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let old = reconciler.apply(event(2, .turnCompleted, source: source))
        _ = reconciler.apply(event(3, .sessionStarted, source: source, turn: nil, notify: false))
        let resumed = reconciler.apply(event(4, .turnCompleted, source: source, turn: "resumed-turn"))
        #expect(resumed.disposition == .accepted)
        #expect(resumed.identity != old.identity)
        #expect(reconciler.apply(event(5, .turnCompleted, source: source)).disposition == .stale)
    }

    @Test(arguments: ["claude", "codex"])
    func explicitMessagesRespectFreshnessAndSessionEnd(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(2, .turnStarted, source: source, notify: false))
        #expect(reconciler.apply(event(3, .messagePublished, source: source, request: "push", occurredAt: 1)).disposition == .stale)
        _ = reconciler.apply(event(4, .sessionEnded, source: source, notify: false))
        #expect(reconciler.apply(event(5, .messagePublished, source: source, request: "push")).disposition == .stale)
    }
    @Test(arguments: ["claude", "codex"])
    func idleReminderCannotReplayAReadCompletion(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let done = reconciler.apply(event(2, .turnCompleted, source: source))
        let idle = event(3, .idleObserved, source: source, turn: nil)
        #expect(reconciler.apply(idle).identity == done.identity)
        #expect(reconciler.lifecycleEvent(idle).draft.declaredPhase == .idle)
        _ = reconciler.apply(event(4, .turnStarted, source: source, turn: "next", notify: false))
        let delayed = reconciler.apply(event(5, .idleObserved, source: source, turn: nil, occurredAt: 20))
        #expect(delayed.disposition == .delayed)
        #expect(!delayed.projectsLifecycle)
        #expect(reconciler.apply(event(6, .approvalRequested, source: source, turn: "next", request: "real", occurredAt: 10)).disposition == .accepted)
    }

    @Test(arguments: ["claude", "codex"])
    func anonymousReminderReusesPendingAttentionWithoutMaskingAnotherRequest(source: String) {
        var reconciler = AgentNotificationReconciler()
        let known = reconciler.apply(event(1, .approvalRequested, source: source, request: "known", occurredAt: 10))
        let reminder = reconciler.apply(event(2, .approvalRequested, source: source, request: nil, occurredAt: 30))
        #expect(reminder.identity == known.identity)
        #expect(!reminder.projectsLifecycle)
        #expect(reminder.notificationEvent?.draft.attention?.notification?.correlationKey == known.identity)
        let newer = reconciler.apply(event(3, .approvalRequested, source: source, request: "another", occurredAt: 20))
        #expect(newer.disposition == .accepted)
        #expect(newer.identity != known.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func independentParallelApprovalsCanArriveOutOfOrder(source: String) {
        var reconciler = AgentNotificationReconciler()
        let newer = reconciler.apply(event(1, .approvalRequested, source: source, request: "newer", occurredAt: 30))
        let earlier = reconciler.apply(event(2, .approvalRequested, source: source, request: "earlier", occurredAt: 20))
        #expect(earlier.disposition == .accepted)
        #expect(earlier.identity != newer.identity)
    }

    @Test func pruningRemovesPresentationContextButKeepsDeliveryReceipts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentJournalStore(databaseURL: root.appendingPathComponent("journal.sqlite"))
        defer { store.close() }
        for sequence in 1...5 {
            _ = try store.append(event(Int64(sequence), .turnCompleted, source: "claude").draft)
        }
        #expect(try store.claimNotification(identity: "already-read"))
        try store.withDatabase { database in
            try AgentJournalStore.pruneIfNeeded(database, maximumCount: 3, retainedCount: 2)
            #expect(try AgentJournalStore.readAttention(database, eventId: "event-1") == nil)
            #expect(try AgentJournalStore.readAttention(database, eventId: "event-5") != nil)
        }
        #expect(try store.events(afterSequence: 0, limit: 10).map(\.draft.eventId) == ["event-4", "event-5"])
        #expect(try !store.claimNotification(identity: "already-read"))
    }
    @Test(arguments: ["claude", "codex"])
    func identitylessResponseClearsOnlyMatchingCurrentTurn(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        let wait = reconciler.apply(event(2, .approvalRequested, source: source))
        let response = event(3, .attentionResolved, source: source, pending: true, notify: false)
        let resolved = reconciler.apply(response)
        #expect(resolved.invalidatedCorrelationKeys == [try #require(wait.identity)])
        #expect(reconciler.lifecycleEvent(response).draft.declaredPhase == .running)
        let later = reconciler.apply(event(4, .approvalRequested, source: source, turn: "turn-2"))
        let replay = event(5, .attentionResolved, source: source, pending: true, notify: false)
        #expect(reconciler.apply(replay).invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.lifecycleEvent(replay).draft.declaredPhase == .needsInput)
        #expect(later.identity != wait.identity)
    }

    @Test(arguments: ["claude", "codex"])
    func ambiguousOrOlderIdentitylessResponsePreservesAttention(source: String) {
        for responseTurn in [nil, "previous", "turn-1"] as [String?] {
            var reconciler = AgentNotificationReconciler()
            _ = reconciler.apply(event(1, .approvalRequested, source: source, request: "first", occurredAt: 10))
            _ = reconciler.apply(event(2, .approvalRequested, source: source, request: "second", occurredAt: 20))
            let response = event(3, .attentionResolved, source: source, turn: responseTurn,
                                 pending: true, notify: false, occurredAt: 15)
            #expect(reconciler.apply(response).invalidatedCorrelationKeys.isEmpty)
            #expect(reconciler.lifecycleEvent(response).draft.declaredPhase == .needsInput)
        }
    }

    @Test(arguments: ["claude", "codex"])
    func lateResolutionCannotReopenCompletedTurn(source: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: source, notify: false))
        _ = reconciler.apply(event(2, .turnCompleted, source: source))
        let late = event(3, .attentionResolved, source: source, request: "ordinary-tool",
                         pending: true, notify: false, occurredAt: 1)
        #expect(reconciler.apply(late).invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.lifecycleEvent(late).draft.declaredPhase == .idle)
    }

    @Test(arguments: ["claude", "codex"])
    func runningAfterQuestionPreservesWaitUntilExplicitAnswer(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        let wait = reconciler.apply(event(1, .questionRequested, source: source, request: "r", occurredAt: 30))
        var work = event(2, .stateChanged, source: source, notify: false, occurredAt: 40).draft
        work.declaredPhase = .running
        let running = AgentJournalEvent(sequence: 2, committedAtMs: 2, draft: work)
        _ = reconciler.apply(running)
        #expect(reconciler.lifecycleEvent(running).draft.declaredPhase == .needsInput)
        let answer = event(3, .attentionResolved, source: source, request: "r", notify: false, occurredAt: 50)
        #expect(reconciler.apply(answer).invalidatedCorrelationKeys == [try #require(wait.identity)])
        #expect(reconciler.lifecycleEvent(answer).draft.declaredPhase == .running)
    }

    @Test(arguments: ["claude", "codex"])
    func queuedWorkBeforeApprovalIsStaleUntilExplicitAnswer(source: String) throws {
        var reconciler = AgentNotificationReconciler()
        let wait = reconciler.apply(event(1, .approvalRequested, source: source, request: "r", occurredAt: 30))
        var work = event(2, .stateChanged, source: source, notify: false, occurredAt: 20).draft
        work.declaredPhase = .running
        let queued = AgentJournalEvent(sequence: 2, committedAtMs: 2, draft: work)
        #expect(reconciler.apply(queued).disposition == .stale)
        #expect(reconciler.lifecycleEvent(queued).draft.declaredPhase == .needsInput)
        let answer = event(3, .attentionResolved, source: source, request: "r", notify: false, occurredAt: 40)
        #expect(reconciler.apply(answer).invalidatedCorrelationKeys == [try #require(wait.identity)])
        #expect(reconciler.lifecycleEvent(answer).draft.declaredPhase == .running)
    }

    @Test(arguments: ["PermissionRequest", "AskUserQuestion", "ExitPlanMode"])
    func quickAnswerSuppressesLateClaudeNotificationPair(nativeEvent: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .questionRequested, source: "claude", turn: nil,
                                  request: "feed-uuid", occurredAt: 0, nativeEvent: nativeEvent))
        let answer = event(2, .attentionResolved, source: "claude", turn: nil, notify: false, occurredAt: 2000)
        _ = reconciler.apply(answer)
        var work = event(3, .stateChanged, source: "claude", turn: nil, notify: false, occurredAt: 3000).draft
        work.declaredPhase = .running
        _ = reconciler.apply(AgentJournalEvent(sequence: 3, committedAtMs: 3, draft: work))
        for sequence: Int64 in 4...5 {
            let reminder = event(sequence, .approvalRequested, source: "claude", turn: nil,
                                 occurredAt: 6000 + sequence, nativeEvent: "Notification")
            let decision = reconciler.apply(reminder)
            #expect(!decision.projectsLifecycle)
            #expect(decision.identity == nil)
            #expect(decision.disposition == .observation)
        }
        #expect(reconciler.lifecycleEvent(answer).draft.declaredPhase == .running)
    }

    @Test(arguments: [Int64(10000), 115000])
    func laterClaudeNotificationStillOpensRealWait(elapsed: Int64) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .approvalRequested, source: "claude", turn: nil,
                                  request: "feed-uuid", occurredAt: 0, nativeEvent: "PermissionRequest"))
        _ = reconciler.apply(event(2, .attentionResolved, source: "claude", turn: nil, notify: false, occurredAt: 2000))
        let reminder = event(3, .approvalRequested, source: "claude", turn: nil,
                             occurredAt: elapsed, nativeEvent: "Notification")
        #expect(reconciler.apply(reminder).disposition == .accepted)
        #expect(reconciler.lifecycleEvent(event(4, .attentionResolved, source: "claude", turn: "wrong", notify: false)).draft.declaredPhase == .needsInput)
    }

    @Test func claudeNotificationWithoutFeedStillOpensWait() {
        var reconciler = AgentNotificationReconciler()
        let reminder = event(1, .approvalRequested, source: "claude", turn: nil, nativeEvent: "Notification")
        #expect(reconciler.apply(reminder).disposition == .accepted)
    }

    @Test func toolIdentityCannotResolveFeedQuestionIdentity() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .questionRequested, source: "claude", turn: nil, request: "tool-id", notify: false))
        _ = reconciler.apply(event(2, .questionRequested, source: "claude", turn: nil, request: "feed-uuid"))
        for sequence: Int64 in 3...4 {
            _ = reconciler.apply(event(sequence, .approvalRequested, source: "claude", turn: nil))
        }
        for sequence: Int64 in 5...9 {
            var work = event(sequence, .stateChanged, source: "claude", turn: nil, notify: false).draft
            work.declaredPhase = .running
            _ = reconciler.apply(AgentJournalEvent(sequence: sequence, committedAtMs: sequence, draft: work))
        }
        let wrong = event(10, .attentionResolved, source: "claude", turn: nil, request: "tool-id", notify: false)
        #expect(reconciler.apply(wrong).invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.lifecycleEvent(wrong).draft.declaredPhase == .needsInput)
    }

    @Test func openRequestCountDistinguishesNilTurnWaitFromNoWait() {
        var reconciler = AgentNotificationReconciler()
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
        _ = reconciler.apply(event(1, .approvalRequested, source: "claude", turn: nil))
        let open = reconciler.openRequests(source: "claude", sessionId: "session")
        #expect(open.count == 1)
        #expect(open.identified.isEmpty)
        #expect(open.unidentifiedTurn == nil)
        #expect(open.nativeTurn == nil)
        _ = reconciler.apply(event(2, .attentionResolved, source: "claude", turn: nil, notify: false))
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    @Test func openRequestsExposesIdentitiesAndNativeTurnWithoutMixingSessions() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .questionRequested, source: "codex", request: "z"))
        _ = reconciler.apply(event(2, .approvalRequested, source: "codex", request: "a"))
        let open = reconciler.openRequests(source: "codex", sessionId: "session")
        #expect(open.identified == ["a", "z"])
        #expect(open.count == 2)
        #expect(open.nativeTurn == "turn-1")
        #expect(open.unidentifiedTurn == nil)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }
    // MARK: cm-128.5 — an answered form retires only a form's wait

    private func typedEvent(_ sequence: Int64, _ kind: AgentJournalEventKind, detail: String?, request: String? = nil,
                            notify: Bool = false, occurredAt: Int64? = nil) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 1000 + sequence,
            draft: AgentJournalEventDraft(eventId: "typed-\(sequence)", kind: kind, occurredAtMs: occurredAt ?? sequence,
                source: "claude", agentKey: "claude_code", sessionId: "session", workspaceId: workspace, surfaceId: surface,
                nativeEvent: "Notification", detail: detail, attention: AgentAttentionContext(
                    requestIdentity: request,
                    notification: notify ? AgentJournalNotification(title: "Claude", subtitle: "", body: "Pick one",
                        category: "idle-reminder") : nil)))
    }

    @Test(arguments: ["elicitation_dialog", "elicitation_url_dialog"])
    func answeredTypeRetiresAFormWait(formType: String) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(typedEvent(1, .turnStarted, detail: nil))
        _ = reconciler.apply(typedEvent(2, .questionRequested, detail: formType))
        let raised = reconciler.apply(typedEvent(3, .questionRequested, detail: formType, notify: true))
        #expect(raised.disposition == .accepted)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        for answered in ["elicitation_response", "elicitation_complete"] {
            var copy = reconciler
            let resolved = copy.apply(typedEvent(4, .attentionResolved, detail: answered))
            #expect(!resolved.invalidatedCorrelationKeys.isEmpty, "\(answered) retired nothing")
            #expect(copy.openRequests(source: "claude", sessionId: "session").count == 0, "\(answered)")
        }
    }

    @Test(arguments: ["permission_prompt", nil] as [String?])
    func answeredTypeRetiresNothingWhenThePendingWaitIsNotAForm(raisedType: String?) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(typedEvent(1, .turnStarted, detail: nil))
        _ = reconciler.apply(typedEvent(2, .approvalRequested, detail: raisedType))
        let raised = reconciler.apply(typedEvent(3, .approvalRequested, detail: raisedType, notify: true))
        #expect(raised.disposition == .accepted)
        for answered in ["elicitation_response", "elicitation_complete"] {
            let resolved = reconciler.apply(typedEvent(4, .attentionResolved, detail: answered))
            #expect(resolved.invalidatedCorrelationKeys.isEmpty, "\(answered) retired \(raisedType ?? "an untyped wait")")
            #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 1, "\(answered)")
        }
    }

    @Test func answeredTypeRetiresNothingWhenAFeedRequestWaits() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(typedEvent(1, .turnStarted, detail: nil))
        let raised = reconciler.apply(typedEvent(2, .approvalRequested, detail: nil, request: "feed-1", notify: true))
        #expect(raised.disposition == .accepted)
        let resolved = reconciler.apply(typedEvent(3, .attentionResolved, detail: "elicitation_response"))
        #expect(resolved.invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").identified == ["feed-1"])
    }

    // MARK: cm-124.6 — a row tool's wait and Claude's own permission notification

    private func rowToolEvent(_ sequence: Int64, _ kind: AgentJournalEventKind = .questionRequested,
                              tool: String = "CmuxDemoTool", request: String? = "toolu_1", turn: String? = nil,
                              occurredAt: Int64, notify: Bool = true, marked: Bool = true) -> AgentJournalEvent {
        AgentJournalEvent(sequence: sequence, committedAtMs: 1000 + sequence,
            draft: AgentJournalEventDraft(eventId: "tool-row-\(sequence)", kind: kind, occurredAtMs: occurredAt,
                source: "claude", agentKey: "claude_code", sessionId: "session", workspaceId: workspace, surfaceId: surface,
                nativeEvent: "PreToolUse", detail: marked ? AgentToolRowMarker.detail(forTool: tool) : nil,
                attention: AgentAttentionContext(turnIdentity: turn, requestIdentity: request,
                    notification: notify ? AgentJournalNotification(title: "Claude Code · Needs your answer", subtitle: "",
                        body: "Waiting for input", category: "needs-input") : nil)))
    }

    private func claudeNotification(_ sequence: Int64, occurredAt: Int64) -> AgentJournalEvent {
        event(sequence, .approvalRequested, source: "claude", turn: nil, occurredAt: occurredAt, nativeEvent: "Notification")
    }

    private func retire(_ sequence: Int64, request: String? = "toolu_1", occurredAt: Int64) -> AgentJournalEvent {
        event(sequence, .attentionResolved, source: "claude", turn: nil, request: request, notify: false, occurredAt: occurredAt)
    }

    @Test func markerRoundTripsAndIgnoresOtherDetails() {
        #expect(AgentToolRowMarker.tool(inDetail: AgentToolRowMarker.detail(forTool: "Write")) == "Write")
        #expect(AgentToolRowMarker.tool(inDetail: "tool-row:") == nil)
        #expect(AgentToolRowMarker.tool(inDetail: "notification-type:idle_prompt") == nil)
        #expect(AgentToolRowMarker.tool(inDetail: nil) == nil)
    }

    @Test func claudeNotificationWhileTheRowToolWaitIsOpenIsOneWaitAndNoSecondBanner() throws {
        var reconciler = AgentNotificationReconciler()
        let wait = reconciler.apply(rowToolEvent(1, occurredAt: 0))
        #expect(wait.disposition == .accepted)
        let reminder = reconciler.apply(claudeNotification(2, occurredAt: 6000))
        #expect(reminder.identity == wait.identity, "the reminder belongs to the one open wait")
        #expect(reminder.disposition == .accepted)
        #expect(!reminder.projectsLifecycle)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
    }

    @Test func claudeNotificationAfterTheKeyRetiredTheRowToolWaitIsAnObservation() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(rowToolEvent(1, occurredAt: 0))
        _ = reconciler.apply(retire(2, occurredAt: 3000))
        let late = reconciler.apply(claudeNotification(3, occurredAt: 6000))
        #expect(late.disposition == .observation)
        #expect(late.identity == nil)
        #expect(!late.projectsLifecycle)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    @Test func planReviewRowWaitGetsTheSameLateGuard() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(rowToolEvent(1, .planReviewRequested, occurredAt: 0))
        _ = reconciler.apply(retire(2, occurredAt: 3000))
        #expect(reconciler.apply(claudeNotification(3, occurredAt: 6000)).disposition == .observation)
    }

    @Test(arguments: [Int64(10000), 15000, 115000])
    func claudeNotificationTenSecondsOrMoreAfterTheRowToolWaitStartedOpensAnApprovalWait(elapsed: Int64) {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(rowToolEvent(1, occurredAt: 0))
        _ = reconciler.apply(retire(2, occurredAt: 3000))
        #expect(reconciler.apply(claudeNotification(3, occurredAt: elapsed)).disposition == .accepted)
    }

    @Test func claudeNotificationWithNoRowToolWaitInTheSessionOpensAnApprovalWait() {
        var reconciler = AgentNotificationReconciler()
        #expect(reconciler.apply(claudeNotification(1, occurredAt: 6000)).disposition == .accepted)
    }

    @Test func anUnmarkedPreToolUseWaitKeepsTodaysRule() {
        // A built-in tool's bypass-mode wait carries no `tool-row:` marker: its late notification opens a wait, as on the base.
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(rowToolEvent(1, occurredAt: 0, marked: false))
        _ = reconciler.apply(retire(2, occurredAt: 3000))
        #expect(reconciler.apply(claudeNotification(3, occurredAt: 6000)).disposition == .accepted)
    }

    @Test func aMarkedWaitFromAnotherSourceGivesNoFeedEvidence() {
        var reconciler = AgentNotificationReconciler()
        var wait = rowToolEvent(1, occurredAt: 0).draft
        wait.source = "codex"
        wait.agentKey = "codex"
        _ = reconciler.apply(AgentJournalEvent(sequence: 1, committedAtMs: 1001, draft: wait))
        #expect(reconciler.apply(claudeNotification(2, occurredAt: 6000)).disposition == .accepted)
    }

    @Test func twoOpenRowToolWaitsEachRetireByTheirOwnToolUseId() throws {
        var reconciler = AgentNotificationReconciler()
        let first = reconciler.apply(rowToolEvent(1, request: "toolu_1", occurredAt: 0))
        let second = reconciler.apply(rowToolEvent(2, request: "toolu_2", occurredAt: 100))
        #expect(first.identity != second.identity)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 2)
        // An id-less resolve (his key) retires neither while two are open.
        let key = event(3, .attentionResolved, source: "claude", turn: nil, notify: false, occurredAt: 500)
        #expect(reconciler.apply(key).invalidatedCorrelationKeys.isEmpty)
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 2)
        let one = reconciler.apply(retire(4, request: "toolu_1", occurredAt: 800))
        #expect(one.invalidatedCorrelationKeys == [try #require(first.identity)])
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        let two = reconciler.apply(retire(5, request: "toolu_2", occurredAt: 900))
        #expect(two.invalidatedCorrelationKeys == [try #require(second.identity)])
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    @Test func aRowToolWaitWithNoPostToolUseClosesAtTheTurnsStop() {
        var reconciler = AgentNotificationReconciler()
        _ = reconciler.apply(event(1, .turnStarted, source: "claude", turn: nil, notify: false, occurredAt: 0))
        _ = reconciler.apply(rowToolEvent(2, occurredAt: 100))
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 1)
        _ = reconciler.apply(event(3, .turnCompleted, source: "claude", turn: nil, notify: false, occurredAt: 5000))
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
    }

    // MARK: cm-124.6 — the join with the CLI: the drafts a row tool's PreToolUse really records

    /// `Fixtures/tool-row-pre-tool-use-drafts.json` is also read by `cmuxTests/CLIToolRowTests`, which fails when the CLI
    /// stops recording exactly these drafts. Fed to the real reconciler here, they must reach the late-reminder guard.
    private func recordedRowToolDrafts(startingAt start: Int64) throws -> [AgentJournalEvent] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/tool-row-pre-tool-use-drafts.json")
        let drafts = try JSONDecoder().decode([AgentJournalEventDraft].self, from: Data(contentsOf: url))
        return drafts.enumerated().map { offset, recorded in
            var draft = recorded
            draft.eventId = "recorded-\(offset)"
            draft.occurredAtMs = start
            draft.workspaceId = workspace
            draft.surfaceId = surface
            return AgentJournalEvent(sequence: start + Int64(offset), committedAtMs: 1000 + start, draft: draft)
        }
    }

    @Test func theCLIsRecordedRowToolDraftsRaiseOneWaitAndTheLateGuardReadsThem() throws {
        var reconciler = AgentNotificationReconciler()
        let recorded = try recordedRowToolDrafts(startingAt: 10)
        #expect(recorded.contains { AgentToolRowMarker.tool(inDetail: $0.draft.detail) == "CmuxDemoTool" && $0.draft.attention?.notification != nil },
                "the recorded banner draft carries the marker")
        let decisions = recorded.map { reconciler.apply($0) }
        #expect(decisions.last?.disposition == .accepted, "the banner's draft raises the wait")
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").identified == ["toolu_demo1"])
        // His first key (an id-less PaneInput resolve) at 3 s, then Claude's own notification at 6 s.
        _ = reconciler.apply(event(20, .attentionResolved, source: "claude", turn: nil, notify: false, occurredAt: 3010, nativeEvent: "PaneInput"))
        #expect(reconciler.openRequests(source: "claude", sessionId: "session").count == 0)
        let late = reconciler.apply(claudeNotification(21, occurredAt: 6010))
        #expect(late.disposition == .observation, "no hand comes back for Claude's late notification")
        #expect(late.identity == nil)
    }

    @Test func theCLIsRecordedRowToolDraftsMakeAnEarlyNotificationAReminderOfThatWait() throws {
        var reconciler = AgentNotificationReconciler()
        var wait: AgentNotificationDecision?
        for recorded in try recordedRowToolDrafts(startingAt: 10) { wait = reconciler.apply(recorded) }
        let reminder = reconciler.apply(claudeNotification(30, occurredAt: 6010))
        #expect(reminder.identity == wait?.identity)
        #expect(!reminder.projectsLifecycle)
    }
}
