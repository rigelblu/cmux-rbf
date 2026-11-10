import CmuxAgentJournal
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct KeypressWaitResolutionTests {
    private struct Fixture {
        let workspace = UUID()
        let surface = UUID()
        var state = AgentLifecycleReducerState()
        var notifications = AgentNotificationReconciler()
        var sequence: Int64 = 0

        @discardableResult
        mutating func append(_ kind: AgentJournalEventKind, source: String = "claude", turn: String? = nil,
                             request: String? = nil, phase: AgentLifecyclePhase? = nil,
                             notify: Bool = false) -> AgentNotificationDecision {
            append(AgentJournalEventDraft(kind: kind, occurredAtMs: sequence + 1,
                source: source, agentKey: source == "claude" ? "claude_code" : source, sessionId: "session",
                workspaceId: workspace.uuidString, surfaceId: surface.uuidString,
                declaredPhase: phase, attention: AgentAttentionContext(turnIdentity: turn, requestIdentity: request,
                    notification: notify ? AgentJournalNotification(title: "Agent", subtitle: "", body: "Answer",
                        category: "needs-permission", correlationKey: "notification") : nil)))
        }

        @discardableResult
        mutating func append(_ draft: AgentJournalEventDraft) -> AgentNotificationDecision {
            sequence += 1
            let event = AgentJournalEvent(sequence: sequence, committedAtMs: sequence, draft: draft)
            let decision = notifications.apply(event)
            if decision.disposition != .stale, decision.projectsLifecycle {
                AgentLifecycleReducer().apply(notifications.lifecycleEvent(event), to: &state)
            }
            return decision
        }

        func input(escape: Bool = false, pane: UUID? = nil) -> [AgentJournalEventDraft] {
            AgentPaneInputResolver().drafts(workspaceId: workspace, surfaceId: pane ?? surface,
                isEscape: escape, state: state, notifications: notifications, occurredAtMs: sequence + 1)
        }

        var phase: AgentLifecyclePhase? {
            state.combinedPhase(surfaceId: surface.uuidString, agentKey: "claude_code")
        }
    }

    @Test(arguments: [AgentJournalEventKind.approvalRequested, .questionRequested, .planReviewRequested])
    func acceptedInputResolvesEachWaitAndInvalidatesItsNotification(kind: AgentJournalEventKind) throws {
        for turn in [nil, "native-turn"] as [String?] {
            for request in [nil, "feed-uuid"] as [String?] {
                var fixture = Fixture()
                fixture.append(kind, turn: turn, request: request, notify: true)
                let drafts = fixture.input()
                #expect(drafts.count == 1)
                let answer = try #require(drafts.first)
                #expect(answer.kind == .attentionResolved)
                #expect(answer.source == "claude")
                #expect(answer.sessionId == "session")
                #expect(answer.nativeEvent == "PaneInput")
                #expect(answer.attention?.requestIdentity == nil)
                #expect(answer.attention?.turnIdentity == turn)
                #expect(!answer.pendingWork)
                #expect(fixture.append(answer).invalidatedCorrelationKeys == ["notification"])
                fixture.append(.stateChanged, phase: .running)
                #expect(fixture.phase == .running)
            }
        }
    }

    @Test func differentPaneAndAmbiguousRequestsSendNothing() {
        var fixture = Fixture()
        fixture.append(.questionRequested, request: "one", notify: true)
        #expect(fixture.input(pane: UUID()).isEmpty)
        fixture.append(.approvalRequested, request: "two", notify: true)
        #expect(fixture.input().isEmpty)
        #expect(fixture.phase == .needsInput)
    }

    @Test func escapeResolvesWaitThenDeclaresUnknown() throws {
        var fixture = Fixture()
        fixture.append(.approvalRequested, request: "feed", notify: true)
        let drafts = fixture.input(escape: true)
        #expect(drafts.map(\.kind) == [.attentionResolved, .stateChanged])
        for draft in drafts { fixture.append(draft) }
        #expect(fixture.phase == .unknown)
        #expect(!AgentJournalLifecycleCenter.lifecycle(for: try #require(fixture.phase)).allowsHibernation)
    }

    @Test func arrowThenEscapeClearsRunningWithoutAnotherResolve() {
        var fixture = Fixture()
        fixture.append(.questionRequested, notify: true)
        for draft in fixture.input() { fixture.append(draft) }
        #expect(fixture.phase == .running)
        let escape = fixture.input(escape: true)
        #expect(escape.map(\.kind) == [.stateChanged])
        for draft in escape { fixture.append(draft) }
        #expect(fixture.phase == .unknown)
        fixture.append(.stateChanged, phase: .running)
        #expect(fixture.phase == .running)
    }

    @Test func escapeOnRunningSessionDeclaresUnknownButIdleAndOrdinaryKeysDoNothing() {
        var fixture = Fixture()
        fixture.append(.turnStarted)
        #expect(fixture.input().isEmpty)
        let escape = fixture.input(escape: true)
        #expect(escape.count == 1)
        #expect(escape.first?.nativeEvent == "PaneInput")
        #expect(escape.first?.declaredPhase == .unknown)
        fixture.append(.turnCompleted)
        #expect(fixture.input(escape: true).isEmpty)
    }

    /// cm-128.5 (Scenario 70): an agent that stopped on an error is not running, so Esc in its pane drafts nothing
    /// and leaves the error mark standing.
    @Test func escapeOnAnErroredPaneDraftsNothingAndLeavesTheError() {
        var fixture = Fixture()
        fixture.append(.turnStarted)
        fixture.append(.errorReported)
        #expect(fixture.phase == .error, "phase \(String(describing: fixture.phase))")
        #expect(fixture.input(escape: true).isEmpty, "Esc on an errored pane must draft nothing")
        #expect(fixture.input().isEmpty)
        #expect(fixture.phase == .error)
    }

    @Test func aFeedQuestionSurvivesItsToolIdAndEndsOnIdentitylessPaneInput() {
        var fixture = Fixture()
        fixture.append(.questionRequested, request: "tool-id")
        fixture.append(.questionRequested, request: "feed-uuid", notify: true)
        fixture.append(.approvalRequested, notify: true)
        fixture.append(.approvalRequested, notify: true)
        for _ in 0..<5 { fixture.append(.stateChanged, phase: .running) }
        fixture.append(.attentionResolved, request: "tool-id")
        #expect(fixture.phase == .needsInput)
        for draft in fixture.input() { fixture.append(draft) }
        #expect(fixture.notifications.openRequests(source: "claude", sessionId: "session").count == 0)
        #expect(fixture.phase == .running)
    }

    @Test func resolutionUsesProvidersOwnSourceAndNativeTurn() throws {
        var fixture = Fixture()
        fixture.append(.approvalRequested, source: "codex", turn: "codex-turn", request: "approval", notify: true)
        let draft = try #require(fixture.input().first)
        #expect(draft.source == "codex")
        #expect(draft.agentKey == "codex")
        #expect(draft.attention?.turnIdentity == "codex-turn")
    }

    // MARK: - The wiring around the resolver (cm-128.1)

    private final class InputRecorder { var escapes: [Bool] = [] }

    /// The flag the key path reads is derived from the workspace's per-pane lifecycle map, the only writer: a Feed wait
    /// counts as a wait, a running agent counts as running, and a manual loader does not.
    @MainActor @Test func theWorkspaceLifecycleMapProjectsOntoThePanesKeyFilter() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let surface = try #require(workspace.terminalPanel(for: panel)?.surface)
        #expect(!surface.agentInputState.requiresKeyInspection(isEscape: false))
        workspace.agentLifecycleStatesByPanelId[panel] = ["cmux.feed.attention:claude": .needsInput]
        #expect(surface.agentInputState.requiresKeyInspection(isEscape: false), "a Feed wait reaches the pane's filter")
        workspace.agentLifecycleStatesByPanelId[panel] = ["manual": .running]
        #expect(!surface.agentInputState.isRunning, "a manual loader is not a running agent")
        workspace.agentLifecycleStatesByPanelId[panel] = ["claude_code": .running]
        #expect(surface.agentInputState.isRunning)
        #expect(!surface.agentInputState.requiresKeyInspection(isEscape: false), "running alone leaves ordinary keys alone")
        #expect(surface.agentInputState.requiresKeyInspection(isEscape: true))
        workspace.agentLifecycleStatesByPanelId[panel] = [:]
        #expect(!surface.agentInputState.requiresKeyInspection(isEscape: true))
    }

    /// The center pushes Claude's vim editor mode onto the pane, so the key filter asks for two Escapes.
    @MainActor @Test func theCenterPushesTheVimEditorModeOntoThePane() async throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let surface = try #require(workspace.terminalPanel(for: panel)?.surface)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"),
            usesVimEditor: { _, _ in true })
        #expect(!surface.agentInputState.usesVimEditor)
        let started = AgentJournalEventDraft(kind: .turnStarted, occurredAtMs: 1, source: "claude", agentKey: "claude_code",
            sessionId: "vim-session", workspaceId: workspace.id.uuidString, surfaceId: panel.uuidString)
        center.observe(started)
        // The center runs its operations in order; this call returns after its own draft is processed.
        _ = await center.admitNotification(AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: 2, source: "claude",
            agentKey: "claude_code", sessionId: "barrier", workspaceId: UUID().uuidString, surfaceId: UUID().uuidString,
            nativeEvent: "Barrier"))
        #expect(surface.agentInputState.usesVimEditor, "the vim flag never reached the pane")
    }

    /// The phone bridge both lanes call: a typed string resolves an open wait and never declares unknown, so ESC from the
    /// phone is ordinary typing. Nothing goes to the journal without a wait, or for an empty string. The two lanes' own
    /// call sites are covered by live Scenario 47.
    @MainActor @Test func phoneTypingResolvesAWaitAndEscapeIsOrdinaryTyping() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let surface = try #require(workspace.terminalPanel(for: panel)?.surface)
        let recorder = InputRecorder()
        surface.onAgentPaneInput = { recorder.escapes.append($0) }
        surface.acceptAgentPhoneTyping("a")
        #expect(recorder.escapes.isEmpty, "no wait open: nothing to resolve")
        surface.agentInputState.needsInput = true
        surface.acceptAgentPhoneTyping("")
        #expect(recorder.escapes.isEmpty, "an empty string is not typing")
        surface.acceptAgentPhoneTyping("a")
        surface.acceptAgentPhoneTyping("\u{1B}")
        #expect(recorder.escapes == [false, false], "ESC from the phone resolves the wait and never declares unknown")
    }
}
