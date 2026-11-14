import CmuxAgentJournal
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Clear Agent State's journal side (cm-128.2): the drafts it writes for a workspace, folded through the same reducer and
/// reconciler the app runs. The builder is new, so its red is by mutation (rbf/AGENTS.md), recorded in the slice's report.
struct AgentClearStateResolverTests {
    private struct Fixture {
        let workspace = UUID()
        let surface = UUID()
        var state = AgentLifecycleReducerState()
        var notifications = AgentNotificationReconciler()
        var sequence: Int64 = 0
        var journal: [AgentJournalEvent] = []

        @discardableResult
        mutating func append(_ kind: AgentJournalEventKind, source: String = "claude", sessionId: String? = "session",
                             surface: UUID? = nil, at: Int64? = nil, turn: String? = nil, request: String? = nil,
                             phase: AgentLifecyclePhase? = nil, notify: Bool = false) -> AgentNotificationDecision {
            append(AgentJournalEventDraft(kind: kind, occurredAtMs: at ?? sequence + 1,
                source: source, agentKey: source == "claude" ? "claude_code" : source, sessionId: sessionId,
                workspaceId: workspace.uuidString, surfaceId: (surface ?? self.surface).uuidString,
                declaredPhase: phase, attention: AgentAttentionContext(turnIdentity: turn, requestIdentity: request,
                    notification: notify ? AgentJournalNotification(title: "Agent", subtitle: "", body: "Answer",
                        category: "needs-permission", correlationKey: "notification-\(request ?? "none")") : nil)))
        }

        @discardableResult
        mutating func append(_ draft: AgentJournalEventDraft) -> AgentNotificationDecision {
            sequence += 1
            let event = AgentJournalEvent(sequence: sequence, committedAtMs: sequence, draft: draft)
            journal.append(event)
            let decision = notifications.apply(event)
            if decision.disposition != .stale, decision.projectsLifecycle {
                AgentLifecycleReducer().apply(notifications.lifecycleEvent(event), to: &state)
            }
            return decision
        }

        func clear(panels: [UUID]? = nil, now: Int64? = nil) -> [AgentJournalEventDraft] {
            AgentClearStateResolver().drafts(workspaceId: workspace, surfaceIds: panels ?? [surface], state: state,
                notifications: notifications, occurredAtMs: now ?? sequence + 1)
        }

        func phase(agentKey: String = "claude_code", surface: UUID? = nil) -> AgentLifecyclePhase? {
            state.combinedPhase(surfaceId: (surface ?? self.surface).uuidString, agentKey: agentKey)
        }

        func openRequests(source: String = "claude") -> Int {
            notifications.openRequests(source: source, sessionId: "session").count
        }
    }

    // MARK: - Scenario 7: a clear survives the next event and a restart

    @Test func aClearClosesTheOpenRequestThenDeclaresUnknownUnderTheAgentsSource() throws {
        var fixture = Fixture()
        fixture.append(.approvalRequested, request: "r", notify: true)
        #expect(fixture.phase() == .needsInput)
        let drafts = fixture.clear()
        #expect(drafts.map(\.kind) == [.attentionResolved, .stateChanged])
        #expect(drafts.allSatisfy { $0.source == "claude" && $0.agentKey == "claude_code" && $0.sessionId == "session" })
        #expect(drafts.allSatisfy { $0.nativeEvent == "ClearAgentState" })
        #expect(drafts.first?.attention?.requestIdentity == "r")
        #expect(drafts.last?.declaredPhase == .unknown)
        for draft in drafts { fixture.append(draft) }
        #expect(fixture.phase() == .unknown)
        #expect(fixture.openRequests() == 0)
        // The next agent event does not bring the wait back.
        fixture.append(.stateChanged, phase: .running)
        #expect(fixture.phase() == .running, "the next running report must show running, not needs input")
    }

    @Test func replayOfTheJournalThroughTheClearPaintsNoWait() {
        var fixture = Fixture()
        fixture.append(.approvalRequested, request: "r", notify: true)
        for draft in fixture.clear() { fixture.append(draft) }
        var replayed = AgentLifecycleReducerState()
        var notifications = AgentNotificationReconciler()
        for event in fixture.journal {
            let decision = notifications.apply(event)
            if decision.disposition != .stale, decision.projectsLifecycle {
                AgentLifecycleReducer().apply(notifications.lifecycleEvent(event), to: &replayed)
            }
        }
        #expect(replayed.combinedPhase(surfaceId: fixture.surface.uuidString, agentKey: "claude_code") == .unknown)
        let painted = AgentJournalReplayPolicy().startupSnapshot(from: replayed.snapshot())
        #expect(painted.phases[fixture.surface.uuidString]?["claude_code"] != .needsInput, "a restart brought the wait back")
        #expect(painted.phases[fixture.surface.uuidString]?["claude_code"] != .running)
    }

    @Test func theSameDraftsUnderAUserSourceLeaveTheAgentsWaitOpen() {
        var fixture = Fixture()
        fixture.append(.approvalRequested, request: "r", notify: true)
        for var draft in fixture.clear() {
            draft.source = "cmux.user"
            draft.agentKey = "cmux.user"
            fixture.append(draft)
        }
        #expect(fixture.phase() == .needsInput, "a clear under another source opens a separate session (probe S1b)")
        #expect(fixture.openRequests() == 1)
    }

    @Test func errorAndRunningSessionsEndAtUnknownAndAClearWritesNoIdle() {
        var errored = Fixture()
        errored.append(.errorReported)
        #expect(errored.phase() == .error)
        let drafts = errored.clear()
        #expect(drafts.map(\.kind) == [.stateChanged])
        for draft in drafts { errored.append(draft) }
        #expect(errored.phase() == .unknown)

        var running = Fixture()
        running.append(.turnStarted)
        let runningDrafts = running.clear()
        #expect(runningDrafts.map(\.kind) == [.stateChanged])
        #expect(runningDrafts.allSatisfy { $0.declaredPhase == .unknown && !$0.pendingWork })
        for draft in runningDrafts { running.append(draft) }
        #expect(running.phase() == .unknown)
        #expect(!AgentJournalLifecycleCenter.lifecycle(for: .unknown).allowsHibernation)
        running.append(.stateChanged, phase: .running)
        #expect(running.phase() == .running, "a real signal after the clear brings real state back")
    }

    @Test func theClearIsStampedNoEarlierThanTheSessionsLastEventSoItIsNotDroppedAsStale() {
        var fixture = Fixture()
        fixture.append(.turnStarted, at: 5_000)
        let drafts = fixture.clear(now: 1_000)
        #expect(drafts.allSatisfy { $0.occurredAtMs == 5_000 })
        for draft in drafts { fixture.append(draft) }
        #expect(fixture.phase() == .unknown)
        // An agent event stamped after the clear wins; one stamped before it, arriving later, is dropped.
        fixture.append(.stateChanged, at: 4_000, phase: .running)
        #expect(fixture.phase() == .unknown)
        fixture.append(.stateChanged, at: 6_000, phase: .running)
        #expect(fixture.phase() == .running)
    }

    // MARK: - Which sessions

    @Test func idleUnknownEndedAndOtherWorkspacesSessionsGetNoDraft() {
        var fixture = Fixture()
        fixture.append(.turnStarted, sessionId: "idle")
        fixture.append(.turnCompleted, sessionId: "idle")
        fixture.append(.sessionStarted, sessionId: "unknown")
        fixture.append(.turnStarted, sessionId: "ended")
        fixture.append(.sessionEnded, sessionId: "ended")
        #expect(fixture.clear().isEmpty, "an all-idle workspace changes nothing")
        let otherPanel = UUID()
        fixture.append(.turnStarted, sessionId: "elsewhere", surface: otherPanel)
        #expect(fixture.clear().isEmpty, "a pane outside the workspace's own panels is not touched")
        #expect(fixture.clear(panels: [otherPanel]).count == 1)
    }

    @Test func everyMarkedSessionOnEveryPanelAndEveryAgentIsClearedButTheIdleOneStays() {
        var fixture = Fixture()
        let second = UUID()
        fixture.append(.turnStarted, sessionId: "a")
        fixture.append(.approvalRequested, sessionId: "b", request: "rb", notify: true)
        fixture.append(.turnStarted, source: "codex", sessionId: "c")
        fixture.append(.turnStarted, sessionId: "d", surface: second)
        fixture.append(.turnStarted, sessionId: "idle", surface: second)
        fixture.append(.turnCompleted, sessionId: "idle", surface: second)
        let drafts = fixture.clear(panels: [fixture.surface, second])
        let cleared = Set(drafts.compactMap(\.sessionId))
        #expect(cleared == ["a", "b", "c", "d"])
        #expect(drafts.filter { $0.kind == .attentionResolved }.count == 1)
        for draft in drafts { fixture.append(draft) }
        #expect(fixture.phase() == .unknown)
        #expect(fixture.phase(agentKey: "codex") == .unknown)
        let idleOnly = fixture.state.sessions[second.uuidString]?["claude_code"]?["idle"]
        #expect(idleOnly?.phase == .idle, "an idle session stays idle, so its pane stays hibernatable")
    }

    @Test func aSessionlessBucketGetsOneSessionlessUnknownAndAnAgentKeyOutsideTheAllowedSetNone() {
        var fixture = Fixture()
        fixture.append(.turnStarted, sessionId: nil)
        let drafts = fixture.clear()
        #expect(drafts.count == 1)
        #expect(drafts.first?.sessionId == nil)
        #expect(drafts.first?.kind == .stateChanged)
        #expect(drafts.first?.nativeEvent == "ClearAgentState")
        for draft in drafts { fixture.append(draft) }
        #expect(fixture.phase() == .unknown)

        var custom = Fixture()
        custom.append(AgentJournalEventDraft(kind: .turnStarted, occurredAtMs: 1, source: "custom-tool",
            agentKey: "custom-tool", sessionId: "s", workspaceId: custom.workspace.uuidString,
            surfaceId: custom.surface.uuidString))
        #expect(custom.clear().isEmpty)
    }

    // MARK: - Scenario 22: an id-less permission wait

    @Test func claudesIdlessWaitWithNoTurnIdIsClosedByAResolveWithANilTurn() throws {
        var fixture = Fixture()
        fixture.append(.approvalRequested, notify: true)
        #expect(fixture.openRequests() == 1)
        let drafts = fixture.clear()
        #expect(drafts.map(\.kind) == [.attentionResolved, .stateChanged], "no resolve was sent for Claude's id-less wait")
        let resolve = try #require(drafts.first)
        #expect(resolve.attention?.requestIdentity == nil)
        #expect(resolve.attention?.turnIdentity == nil)
        for draft in drafts { fixture.append(draft) }
        #expect(fixture.openRequests() == 0)
        #expect(fixture.phase() == .unknown)
        fixture.append(.stateChanged, phase: .running)
        #expect(fixture.phase() == .running, "the id-less wait came back as needs input")
    }

    @Test func anIdlessWaitOnATurnIsClosedByAResolveCarryingThatTurn() throws {
        var fixture = Fixture()
        fixture.append(.approvalRequested, source: "codex", turn: "T", notify: true)
        let drafts = fixture.clear()
        let resolve = try #require(drafts.first)
        #expect(resolve.kind == .attentionResolved)
        #expect(resolve.attention?.turnIdentity == "T")
        for draft in drafts { fixture.append(draft) }
        #expect(fixture.notifications.openRequests(source: "codex", sessionId: "session").count == 0)
        fixture.append(.stateChanged, source: "codex", phase: .running)
        #expect(fixture.phase(agentKey: "codex") == .running)
    }

    @Test func anIdlessWaitThenAnIdWaitIsClosedByOneResolveByIdThenOneIdless() throws {
        var fixture = Fixture()
        fixture.append(.approvalRequested, notify: true)
        fixture.append(.questionRequested, request: "q", notify: true)
        #expect(fixture.openRequests() == 2)
        let drafts = fixture.clear()
        #expect(drafts.map(\.kind) == [.attentionResolved, .attentionResolved, .stateChanged])
        try #require(drafts.count == 3)
        #expect(drafts[0].attention?.requestIdentity == "q")
        #expect(drafts[1].attention?.requestIdentity == nil)
        for draft in drafts { fixture.append(draft) }
        #expect(fixture.openRequests() == 0)
        fixture.append(.stateChanged, phase: .running)
        #expect(fixture.phase() == .running)
    }
}
