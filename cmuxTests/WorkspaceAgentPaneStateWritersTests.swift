import CmuxSidebar
import CmuxWorkspaces
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cm-128.6 (Scenarios 24, 92 and 96): a pane's per-agent states. One function computes them, and the row, the workspace
/// signals and Clear Agent State all read it: a Feed attention slot stands in for its agent, a registered Vault agent is an
/// agent, a `cmux workspace loading` loader is none, and within one agent the newest session shows.
@MainActor
@Suite("Per-agent pane states", .serialized)
struct WorkspaceAgentPaneStateWritersTests {
    private let slot = FeedCoordinator.attentionStatusKey(forSource: "claude")

    private func rowSnapshot(
        _ workspace: Workspace,
        list: WorkspaceStatusList = .cmuxFive,
        settingOn: Bool = true,
        showsAgentActivity: Bool = true
    ) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let suite = "WorkspaceAgentPaneStateWritersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if !settingOn { defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showAgentActivityKey) }
        return SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: showsAgentActivity,
            todoControlsEnabled: true, statusList: list, statusColorHexes: [:]
        ).makeSnapshot()
    }

    // MARK: The key test

    @Test func theKeyTestTakesEveryKeyButALoader() {
        for key in ["claude_code", "codex", "my-vault-agent", "cmux.feed.attention:claude_code"] {
            #expect(Workspace.isAgentMarkLifecycleKey(key), "\(key) can hold an agent mark")
        }
        for key in ["manual", "manual:build"] {
            #expect(!Workspace.isAgentMarkLifecycleKey(key), "\(key) is a loader")
        }
    }

    // MARK: Scenario 24, the Feed slot stands in for its agent

    @Test func aFeedSlotStandsInForItsAgentWhileItExists() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = [slot: .needsInput, "claude_code": .running]
        let snapshot = rowSnapshot(workspace)
        let signals = workspace.taskStatusSignals()
        #expect(snapshot.showsRaisedHand, "the slot raises the hand")
        #expect(snapshot.activeCodingAgentCount == 0, "Claude Code, standing behind its slot, draws no spinner")
        #expect(signals.anyAgentNeedsInput && signals.anyAgentWaiting)
        #expect(!signals.anyAgentRunning, "the slot stands in for the key, so nothing runs")
        #expect(!signals.anyAgentError)
        #expect(workspace.agentHibernationLifecycleState(panelId: panel, fallback: nil) == .running,
                "hibernation's aggregate keeps every key, so the pane still reads running")
    }

    @Test func anotherAgentRunningBesideASlotShowsItsOwnSpinner() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = [slot: .needsInput, "claude_code": .running, "codex": .running]
        let snapshot = rowSnapshot(workspace)
        #expect(snapshot.showsRaisedHand)
        #expect(snapshot.activeCodingAgentCount == 1, "only Codex runs")
        #expect(workspace.taskStatusSignals().anyAgentRunning)
    }

    @Test func whenTheSlotGoesTheAgentIsRunningAgain() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = [slot: .needsInput, "claude_code": .running]
        #expect(rowSnapshot(workspace).showsRaisedHand && rowSnapshot(workspace).activeCodingAgentCount == 0, "control: the slot stands in")
        workspace.agentLifecycleStatesByPanelId[panel] = ["claude_code": .running] // the Feed concluded and removed its slot
        let snapshot = rowSnapshot(workspace)
        #expect(!snapshot.showsRaisedHand)
        #expect(snapshot.activeCodingAgentCount == 1)
        #expect(workspace.taskStatusSignals().anyAgentRunning)
    }

    @Test func aLoaderBesideAWaitingAgentShowsTheHandAndTheSpinner() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["claude_code": .needsInput, "manual:build": .running]
        let snapshot = rowSnapshot(workspace)
        let signals = workspace.taskStatusSignals()
        #expect(snapshot.showsRaisedHand)
        #expect(snapshot.activeCodingAgentCount == 1, "the loader is a running loader")
        #expect(signals.anyAgentRunning, "a loader still counts as running for the socket and Auto's Working")
        #expect(signals.anyAgentNeedsInput && signals.anyAgentWaiting && !signals.anyAgentError)
    }

    @Test func aLoaderAloneIsWorkingForAutoAndCountsInSignals() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["manual:build": .running]
        let snapshot = rowSnapshot(workspace)
        let signals = workspace.taskStatusSignals()
        #expect(snapshot.activeCodingAgentCount == 1, "the loader alone spins")
        #expect(signals.anyAgentRunning, "a loader alone counts as running in the signals")
        #expect(workspace.inferredTaskStatus(list: .cmuxFive) == .working, "a loader alone infers Working")
    }

    // MARK: Scenario 92, the signals follow the same states

    @Test func twoAgentsOnOnePaneEachShowTheirOwn() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["codex": .needsInput, "claude_code": .running]
        let snapshot = rowSnapshot(workspace)
        let signals = workspace.taskStatusSignals()
        #expect(snapshot.showsRaisedHand && snapshot.activeCodingAgentCount == 1)
        #expect(signals.anyAgentNeedsInput && signals.anyAgentRunning)
        #expect(signals.anyAgentWaiting, "the hand reads this one")
        #expect(!signals.anyAgentError)
    }

    @Test func anErrorIsNeedsYouButNotTheHandAndNotWaiting() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["claude_code": .error]
        let signals = workspace.taskStatusSignals()
        #expect(signals.anyAgentError && signals.anyAgentNeedsInput)
        #expect(!signals.anyAgentWaiting)
        #expect(!rowSnapshot(workspace).showsRaisedHand)
    }

    @Test func aVaultAgentWaitingAloneRaisesTheHand() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["my-vault-agent": .needsInput]
        let snapshot = rowSnapshot(workspace)
        #expect(snapshot.showsRaisedHand)
        let signals = workspace.taskStatusSignals()
        #expect(signals.anyAgentNeedsInput && signals.anyAgentWaiting && !signals.anyAgentError)
        #expect(SidebarAgentMarkTooltip.lines(.waiting, in: snapshot.agentLists) == ["An agent is waiting for your answer"])
    }

    @Test func aVaultAgentIdleAloneDrawsNoMark() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["my-vault-agent": .idle]
        let snapshot = rowSnapshot(workspace)
        let signals = workspace.taskStatusSignals()
        #expect(!snapshot.showsRaisedHand && snapshot.activeCodingAgentCount == 0 && snapshot.monitoringAgentCount == 0)
        #expect(!signals.anyAgentNeedsInput && !signals.anyAgentRunning && !signals.anyAgentWaiting && !signals.anyAgentError)
        #expect(snapshot.agentLists.idle == [SidebarAgentStateEntry(statusKey: "", displayName: nil, paneCount: 1, usageLimit: false)])
    }

    @Test func aVaultAgentRunningIsAnAgentAndNotALoader() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["my-vault-agent": .running]
        #expect(rowSnapshot(workspace).activeCodingAgentCount == 1)
        let signals = workspace.taskStatusSignals()
        #expect(signals.anyAgentRunning && !signals.anyAgentWaiting && !signals.anyAgentError && !signals.anyAgentNeedsInput)
    }

    @Test func aNewerWaitingSessionRaisesTheHandAndInfersNeedsAttention() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.turnStarted, sessionId: "old")
            harness.observe(.approvalRequested, sessionId: "new", request: "q6", correlationKey: "q6")
            await harness.settle()
            #expect(harness.marks["claude_code"] == .needsInput, "marks \(harness.marks)")
            #expect(rowSnapshot(harness.workspace).showsRaisedHand)
            #expect(harness.workspace.inferredTaskStatus(list: .cmuxFive) == .needsAttention)
            let signals = harness.workspace.taskStatusSignals()
            #expect(signals.anyAgentWaiting && !signals.anyAgentError)
        }
    }

    /// The case 17:53 names: an older session's stale wait under a newer session that errored. The error decides, so the row
    /// infers Needs Attention from the error itself, and the hand does not show.
    @Test func anOlderWaitUnderANewerErrorInfersNeedsAttentionFromTheError() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.approvalRequested, sessionId: "old", request: "q6e", correlationKey: "q6e")
            harness.observe(.errorReported, sessionId: "new")
            await harness.settle()
            #expect(harness.marks["claude_code"] == .error, "marks \(harness.marks)")
            let signals = harness.workspace.taskStatusSignals()
            #expect(signals.anyAgentError && signals.anyAgentNeedsInput && !signals.anyAgentWaiting)
            #expect(!rowSnapshot(harness.workspace).showsRaisedHand)
            #expect(harness.workspace.inferredTaskStatus(list: .cmuxFive) == .needsAttention)
        }
    }

    @Test func aNewerRunningSessionIsWorkingNotWaiting() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.approvalRequested, sessionId: "old", request: "q6b", correlationKey: "q6b")
            harness.observe(.turnStarted, sessionId: "new")
            await harness.settle()
            #expect(harness.marks["claude_code"] == .running, "marks \(harness.marks)")
            let snapshot = rowSnapshot(harness.workspace)
            #expect(!snapshot.showsRaisedHand && snapshot.activeCodingAgentCount == 1)
            #expect(harness.workspace.inferredTaskStatus(list: .cmuxFive) == .working)
            let signals = harness.workspace.taskStatusSignals()
            #expect(!signals.anyAgentWaiting && !signals.anyAgentError && signals.anyAgentRunning)
        }
    }

    // MARK: Scenario 17 and 24, the lists name the agents in each state

    @Test func theListsNameEachAgentInItsState() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = [
            "claude_code": .needsInput, "codex": .error, "pi": .running, "amp": .monitoring, "gemini": .idle]
        let lists = rowSnapshot(workspace).agentLists
        #expect(lists.waiting.map(\.displayName) == ["Claude Code"], "\(lists.waiting)")
        #expect(lists.error.map(\.displayName) == ["Codex"], "\(lists.error)")
        #expect(lists.running.map(\.statusKey) == ["pi"], "\(lists.running)")
        #expect(lists.monitoring.map(\.statusKey) == ["amp"], "\(lists.monitoring)")
        #expect(lists.idle.map(\.statusKey) == ["gemini"], "\(lists.idle)")
        #expect(lists.loaderCount == 0)
    }

    @Test func aSlotMovesItsAgentFromTheRunningListToTheWaitingList() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = [slot: .needsInput, "claude_code": .running, "codex": .running]
        let lists = rowSnapshot(workspace).agentLists
        #expect(lists.waiting.map(\.statusKey) == ["claude_code"], "the slot's name has its prefix taken off: \(lists.waiting)")
        #expect(lists.running.map(\.statusKey) == ["codex"], "\(lists.running)")
        workspace.agentLifecycleStatesByPanelId[panel] = ["claude_code": .running, "codex": .running]
        let without = rowSnapshot(workspace).agentLists
        #expect(without.waiting.isEmpty && without.running.map(\.statusKey) == ["claude_code", "codex"], "\(without)")
    }

    @Test func everyNamelessAgentInAStateIsOneEntryWithTheirCount() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["vault-a": .needsInput, "vault-b": .needsInput, "vault-c": .idle]
        let lists = rowSnapshot(workspace).agentLists
        #expect(lists.waiting.count == 1 && lists.waiting.first?.displayName == nil && lists.waiting.first?.paneCount == 2, "\(lists.waiting)")
        #expect(lists.idle.count == 1 && lists.idle.first?.displayName == nil, "a Vault agent can be idle: \(lists.idle)")
        #expect(rowSnapshot(workspace).showsRaisedHand, "a Vault agent waiting raises the hand")
    }

    @Test func aLoaderIsCountedApartAndAddsToTheSpinner() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["manual:build": .running, "manual": .running, "claude_code": .running]
        let lists = rowSnapshot(workspace).agentLists
        #expect(lists.loaderCount == 2 && lists.running.map(\.paneCount) == [1])
        #expect(lists.activeCodingAgentCount == 3, "nameless running agents and loaders count together")
    }

    @Test func eachListKeepsItsMarksGate() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = [
            "claude_code": .needsInput, "codex": .error, "pi": .running, "amp": .monitoring, "gemini": .idle, "manual:x": .running]
        let off = rowSnapshot(workspace, settingOn: false).agentLists
        #expect(off.waiting.isEmpty && off.error.isEmpty, "the setting hides the two needs-you lists")
        #expect(!off.running.isEmpty && !off.monitoring.isEmpty && !off.idle.isEmpty && off.loaderCount == 1,
                "the setting alone does not gate the others: the factory's showsAgentActivity does")
        let noActivity = rowSnapshot(workspace, showsAgentActivity: false).agentLists
        #expect(!noActivity.waiting.isEmpty && !noActivity.error.isEmpty, "the hand ignores the spinner flag")
        #expect(noActivity.running.isEmpty && noActivity.monitoring.isEmpty && noActivity.idle.isEmpty && noActivity.loaderCount == 0)
        let none = rowSnapshot(workspace, settingOn: false, showsAgentActivity: false).agentLists
        #expect(none == SidebarAgentStateLists(), "every list is empty: \(none)")
    }

    @Test func theUsageLimitFlagIsReadForEachErrorAndJoinsTheListsEquality() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        workspace.agentLifecycleStatesByPanelId[panel] = ["claude_code": .error]
        let plain = rowSnapshot(workspace).agentLists
        workspace.setAgentUsageLimit(key: "claude_code", panelId: panel)
        let limited = rowSnapshot(workspace).agentLists
        #expect(plain.error.first?.usageLimit == false && limited.error.first?.usageLimit == true)
        #expect(plain != limited, "an error to an error without the limit redraws the row")
    }

    @Test func aNewerWaitingSessionMovesItsAgentToTheWaitingList() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.turnStarted, sessionId: "old")
            harness.observe(.approvalRequested, sessionId: "new", request: "q6c", correlationKey: "q6c")
            await harness.settle()
            let lists = rowSnapshot(harness.workspace).agentLists
            #expect(lists.waiting.map(\.statusKey) == ["claude_code"] && lists.running.isEmpty, "\(lists)")
        }
    }

    @Test func theSignalsAndTheListsAgreeOnEveryStateCombination() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let combos: [[String: AgentHibernationLifecycleState]] = [
            [:], ["claude_code": .needsInput], ["claude_code": .error], ["claude_code": .running], ["claude_code": .monitoring],
            ["claude_code": .idle], ["manual:x": .running], [slot: .needsInput, "claude_code": .running],
            ["codex": .error, "claude_code": .needsInput], ["vault": .running, "claude_code": .monitoring]]
        for states in combos {
            workspace.agentLifecycleStatesByPanelId = states.isEmpty ? [:] : [panel: states]
            let lists = rowSnapshot(workspace).agentLists
            let signals = workspace.taskStatusSignals()
            #expect(signals.anyAgentWaiting == !lists.waiting.isEmpty, "waiting \(states)")
            #expect(signals.anyAgentError == !lists.error.isEmpty, "error \(states)")
            #expect(signals.anyAgentNeedsInput == (!lists.waiting.isEmpty || !lists.error.isEmpty), "needs input \(states)")
            #expect(signals.anyAgentRunning == (lists.activeCodingAgentCount > 0), "running \(states)")
            #expect(signals.anyAgentMonitoring == !lists.monitoring.isEmpty, "monitoring \(states)")
        }
    }
}
