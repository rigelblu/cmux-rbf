import AppKit
import CMUXAgentLaunch
import CmuxAgentJournal
import CmuxSidebar
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// One workspace in a registered window with its own journal center, for the app side of Clear Agent State (cm-128.2).
/// Nothing here reads the shared center, so a test's events reach only its own workspace.
@MainActor
final class ClearAgentStateHarness {
    /// A delegate of its own: the harness registers its window on it and hands it to the journal center, so neither
    /// `AppDelegate.shared` (which suites outside the gate swap and read) nor the process's real delegate holds this window.
    let appDelegate: AppDelegate
    private let previousAppDelegate: AppDelegate?
    let windowId: UUID
    let tabManager: TabManager
    let workspace: Workspace
    let panel: UUID
    let center: AgentJournalLifecycleCenter
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let previousPresence = MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting
    private var clock = Int64(Date().timeIntervalSince1970 * 1000)

    /// Runs `body` inside the app-context gate because these tests use shared notification and Feed state.
    static func run<T>(_ body: @MainActor (ClearAgentStateHarness) async throws -> T) async throws -> T {
        try await AppContextSerialGate.withExclusiveAppContext {
            let harness = try ClearAgentStateHarness()
            defer { harness.close() }
            return try await body(harness)
        }
    }

    fileprivate init() throws {
        _ = NSApplication.shared
        previousAppDelegate = AppDelegate.shared
        appDelegate = AppDelegate()
        // AppDelegate.init assigns shared. Restore it before this synchronous main-actor job can yield to another suite.
        AppDelegate.shared = previousAppDelegate
        tabManager = TabManager(autoWelcomeIfNeeded: false)
        windowId = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager)
        workspace = tabManager.addWorkspace(select: true)
        panel = try #require(workspace.focusedPanelId)
        let host = appDelegate
        center = AgentJournalLifecycleCenter(databaseURL: root.appendingPathComponent("journal.sqlite"),
            appDelegate: { [weak host] in host })
    }

    func close() {
        if tabManager.tabs.contains(where: { $0.id == workspace.id }) { tabManager.closeWorkspace(workspace) }
        appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
        // AppDelegate.init sets shared and the route retirer together, so the saved shared delegate is the retirer
        // this harness displaced. The registry exposes attachment only; restore that composition owner on close.
        if let previousAppDelegate {
            GhosttyApp.terminalSurfaceRegistry.attachRouteRetirer(previousAppDelegate)
        }
        MobileWorkspaceListObserver.subscriberPresenceOverrideForTesting = previousPresence
        try? FileManager.default.removeItem(at: root)
    }

    /// Sends one agent event for the workspace's pane through the center, as a hook would.
    func observe(_ kind: AgentJournalEventKind, sessionId: String = "session", source: String = "claude",
                 request: String? = nil, phase: AgentLifecyclePhase? = nil, correlationKey: String? = nil,
                 pending: Bool = false) {
        clock = max(clock + 1, Int64(Date().timeIntervalSince1970 * 1000))
        center.observe(AgentJournalEventDraft(kind: kind, occurredAtMs: clock, source: source,
            agentKey: source == "claude" ? "claude_code" : source, sessionId: sessionId,
            workspaceId: workspace.id.uuidString, surfaceId: panel.uuidString, pendingWork: pending, declaredPhase: phase,
            attention: AgentAttentionContext(requestIdentity: request, notification: correlationKey.map {
                AgentJournalNotification(title: "Agent", subtitle: "", body: "Answer", category: "needs-permission",
                    correlationKey: $0)
            })))
    }

    /// Returns once the center has processed everything queued before the call.
    func settle() async {
        _ = await center.admitNotification(AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: 1, source: "claude",
            agentKey: "claude_code", sessionId: "barrier", workspaceId: UUID().uuidString, surfaceId: UUID().uuidString,
            nativeEvent: "Barrier"))
        await Task.yield()
    }

    var marks: [String: AgentHibernationLifecycleState] { workspace.agentLifecycleStatesByPanelId[panel] ?? [:] }

    func state(fallback: AgentHibernationLifecycleState?) -> AgentHibernationLifecycleState {
        workspace.agentHibernationLifecycleState(panelId: panel, fallback: fallback)
    }
}

@MainActor
@Suite("Clear Agent State harness isolation", .serialized)
struct ClearAgentStateHarnessIsolationTests {
    @Test func constructingAndClosingTheHarnessPreservesTheSharedDelegateAndPiDeliveryTarget() async throws {
        let event = WorkstreamEvent(sessionId: "harness-isolation", hookEventName: .postToolUse,
            source: "pi", workspaceId: UUID().uuidString, surfaceId: UUID().uuidString,
            toolName: "Bash", requestId: "harness-isolation-request")
        func closedTargetIsNotFound() -> Bool {
            if case .notFound = FeedCoordinator.shared.resolveDeliveryTarget(for: [event]) { return true }
            return false
        }
        weak var privateDelegate: AppDelegate?
        let journal: AgentJournalLifecycleCenter
        // The control's temporary startup flag and the harness lifetime stay in one main-actor job.
        do {
            let expected = try #require(AppDelegate.shared)
            let previousRestore = expected.didAttemptStartupSessionRestore
            expected.didAttemptStartupSessionRestore = true
            defer { expected.didAttemptStartupSessionRestore = previousRestore }
            #expect(closedTargetIsNotFound(), "control: a closed Pi target resolves not_found")
            let harness = try ClearAgentStateHarness()
            privateDelegate = harness.appDelegate
            journal = harness.center
            #expect(AppDelegate.shared === expected, "constructing the harness replaced AppDelegate.shared")
            #expect(closedTargetIsNotFound(), "constructing the harness changed Pi's closed target from not_found")
            harness.close()
            #expect(AppDelegate.shared === expected, "closing the harness did not restore AppDelegate.shared")
            #expect(closedTargetIsNotFound(), "closing the harness left Pi's closed target unavailable")
        }
        await Task.yield()
        // Keep the journal alive so this probes the capture itself, independently of consumer cancellation timing.
        withExtendedLifetime(journal) {
            #expect(privateDelegate == nil, "the journal worker retained the harness delegate after close")
        }
    }
}

/// A clear never makes a working pane hibernatable, and leaves the row with no mark for every state it can meet
/// (cm-128.2, Scenarios 8 and 19).
@MainActor
@Suite("Clear Agent State leaves panes unknown", .serialized)
struct AgentClearHibernationTests {
    @Test func aMonitoringOnlyPaneWithoutAPillEnablesClearAndStaysUnknownAfterALaterObservation() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.turnStarted)
            harness.observe(.turnCompleted, pending: true)
            await harness.settle()
            #expect(harness.marks["claude_code"] == .monitoring)
            #expect(rowSnapshot(harness.workspace).monitoringAgentCount == 1)
            #expect(!harness.workspace.statusEntries.keys.contains(where: Workspace.isAgentStatusPillKey))
            #expect(harness.workspace.hasClearableAgentState)
            #expect(harness.tabManager.canClearAgentState(workspaceIds: [harness.workspace.id]))
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            await harness.settle()
            #expect(harness.marks["claude_code"] == .unknown)
            harness.observe(.idleObserved, pending: true)
            await harness.settle()
            #expect(harness.marks["claude_code"] == .unknown)
            harness.observe(.sessionStarted)
            await harness.settle()
            #expect(harness.marks["claude_code"] == .unknown, "the clear must reach the journal's own state")
            #expect(harness.state(fallback: .idle) == .unknown)
            #expect(!harness.state(fallback: .idle).allowsHibernation)
            let snapshot = rowSnapshot(harness.workspace)
            #expect(snapshot.activeCodingAgentCount == 0)
            #expect(snapshot.monitoringAgentCount == 0)
            #expect(!snapshot.showsRaisedHand)
        }
    }

    @Test func aRestoredMonitoringKeyIsSetUnknownEvenWithoutAJournalSession() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panel, lifecycle: .monitoring)
            harness.workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Running")
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            await harness.settle()
            #expect(harness.marks["claude_code"] == .unknown)
            #expect(harness.state(fallback: .idle) == .unknown)
            #expect(harness.workspace.statusEntries["claude_code"] == nil)
        }
    }

    private func rowSnapshot(_ workspace: Workspace) -> SidebarWorkspaceSnapshotBuilder.Snapshot {
        let suite = "AgentClearHibernationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        return SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: true,
            todoControlsEnabled: true, statusList: WorkspaceStatusEntrancesTests.hisList, statusColorHexes: [:]
        ).makeSnapshot()
    }

    // MARK: - Scenario 8

    @Test func aClearWritesTheJournalSoTheNextRunningSignalCannotBringTheWaitBack() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.approvalRequested, request: "journal-clear", correlationKey: "journal-clear")
            await harness.settle()
            #expect(harness.marks["claude_code"] == .needsInput)
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            await harness.settle()
            #expect(harness.marks["claude_code"] == .unknown)
            harness.center.observe(AgentJournalEventDraft(kind: .stateChanged,
                occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000) + 1,
                source: "claude", agentKey: "claude_code", sessionId: "session",
                workspaceId: harness.workspace.id.uuidString, surfaceId: harness.panel.uuidString,
                declaredPhase: .running))
            await harness.settle()
            #expect(harness.marks["claude_code"] == .running,
                "the shared action did not retire the wait in the journal; its next running signal brought the hand back")
        }
    }

    @Test func anEventStampedBeforeTheClearCannotBringTheHandBackWhenDeliveredAfterIt() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.turnStarted)
            await harness.settle()
            #expect(harness.marks["claude_code"] == .running)
            let stale = AgentJournalEventDraft(kind: .approvalRequested,
                occurredAtMs: Int64(Date().timeIntervalSince1970 * 1000) - 1,
                source: "claude", agentKey: "claude_code", sessionId: "session",
                workspaceId: harness.workspace.id.uuidString, surfaceId: harness.panel.uuidString,
                attention: AgentAttentionContext(requestIdentity: "stale-before-clear"))
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            await harness.settle()
            #expect(harness.marks["claude_code"] == .unknown)
            harness.center.observe(stale)
            await harness.settle()
            #expect(harness.marks["claude_code"] == .unknown,
                "an event stamped before the clear brought the hand back when delivered afterwards")
        }
    }

    @Test func aRunningSessionEndsUnknownAndNotHibernatableEvenWhenTheCliRecordSaysIdle() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.turnStarted)
            await harness.settle()
            #expect(harness.marks["claude_code"] == .running, "control: the journal's running reached the pane")
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            await harness.settle()
            #expect(harness.marks["claude_code"] == .unknown)
            let state = harness.state(fallback: .idle)
            #expect(state == .unknown)
            #expect(!state.allowsHibernation, "a clear made a working pane hibernatable")
        }
    }

    @Test func aSocketWrittenKeyIsSetToUnknownNotRemoved() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.setAgentLifecycle(key: "codex", panelId: harness.panel, lifecycle: .running)
            #expect(harness.state(fallback: .idle) == .running)
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            await harness.settle()
            #expect(harness.marks["codex"] == .unknown, "removing the key lets the pane fall back to the CLI record")
            let state = harness.state(fallback: .idle)
            #expect(state == .unknown)
            #expect(!state.allowsHibernation)
        }
    }

    @Test func aPaneWhoseOnlyAgentKeyWasTheFeedSlotAlsoReadsUnknown() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.agentLifecycleStatesByPanelId[harness.panel] = ["cmux.feed.attention:claude_code": .needsInput]
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            #expect(harness.marks["cmux.feed.attention:claude_code"] == nil)
            let state = harness.state(fallback: .idle)
            #expect(state == .unknown, "with the slot gone the pane fell back to the idle CLI record")
            #expect(!state.allowsHibernation)
        }
    }

    @Test func anIdleAgentAndAManualLoaderAreLeftAlone() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.turnStarted, sessionId: "idle")
            harness.observe(.turnCompleted, sessionId: "idle")
            await harness.settle()
            harness.workspace.setAgentLifecycle(key: "manual", panelId: harness.panel, lifecycle: .running)
            #expect(harness.marks["claude_code"] == .idle)
            #expect(!harness.workspace.hasClearableAgentState)
            #expect(!harness.workspace.clearAgentState(journal: harness.center), "nothing to clear changes nothing")
            await harness.settle()
            #expect(harness.marks["claude_code"] == .idle, "an idle pane must stay hibernatable")
            #expect(harness.marks["manual"] == .running)
        }
    }

    // MARK: - Scenario 19: the row after a clear, for each state

    @Test func aJournalWaitLeavesNoHandAndNoPill() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.approvalRequested, correlationKey: "wait")
            await harness.settle()
            harness.workspace.statusEntries["claude_code"] = SidebarStatusEntry(key: "claude_code", value: "Needs input",
                icon: nil, color: nil, timestamp: Date())
            #expect(rowSnapshot(harness.workspace).showsRaisedHand, "control: the instrument sees the hand")
            #expect(harness.workspace.taskStatusSignals().anyAgentNeedsInput)
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            await harness.settle()
            let snapshot = rowSnapshot(harness.workspace)
            #expect(!snapshot.showsRaisedHand)
            #expect(snapshot.metadataEntries.isEmpty)
            let signals = harness.workspace.taskStatusSignals()
            #expect(!signals.anyAgentNeedsInput && !signals.anyAgentRunning)
            #expect(harness.marks["claude_code"] == .unknown)
        }
    }

    @Test func theFeedsAttentionSlotLeavesNoHandAndNoPill() async throws {
        try await ClearAgentStateHarness.run { harness in
            let slot = FeedCoordinator.attentionStatusKey(forSource: "claude")
            harness.workspace.agentLifecycleStatesByPanelId[harness.panel] = [slot: .needsInput]
            harness.workspace.statusEntries[slot] = SidebarStatusEntry(key: slot, value: "Needs input", icon: nil,
                color: nil, timestamp: Date())
            #expect(rowSnapshot(harness.workspace).showsRaisedHand)
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            #expect(!(rowSnapshot(harness.workspace)).showsRaisedHand, "the Feed slot kept the hand")
            #expect(harness.workspace.statusEntries[slot] == nil)
            #expect(!harness.workspace.taskStatusSignals().anyAgentNeedsInput)
        }
    }

    @Test func aRunningAgentAndASocketSetRunningLeaveNoSpinner() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.observe(.turnStarted)
            await harness.settle()
            harness.workspace.setAgentLifecycle(key: "codex", panelId: harness.panel, lifecycle: .running)
            #expect(harness.workspace.taskStatusSignals().anyAgentRunning)
            #expect(rowSnapshot(harness.workspace).activeCodingAgentCount > 0)
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            await harness.settle()
            #expect(!harness.workspace.taskStatusSignals().anyAgentRunning, "a socket-set running stayed")
            #expect(rowSnapshot(harness.workspace).activeCodingAgentCount == 0)
            #expect(harness.marks["codex"] == .unknown && harness.marks["claude_code"] == .unknown)
        }
    }

    @Test func aPillAloneIsClearedAndHisOwnPillStays() async throws {
        try await ClearAgentStateHarness.run { harness in
            harness.workspace.statusEntries["build"] = SidebarStatusEntry(key: "build", value: "compiling", icon: nil,
                color: nil, timestamp: Date())
            #expect(!harness.workspace.hasClearableAgentState)
            harness.workspace.statusEntries["codex"] = SidebarStatusEntry(key: "codex", value: "Running", icon: nil,
                color: nil, timestamp: Date())
            harness.workspace.statusEntries["codex.session-1"] = SidebarStatusEntry(key: "codex.session-1", value: "x",
                icon: nil, color: nil, timestamp: Date())
            #expect(harness.workspace.hasClearableAgentState)
            #expect(harness.workspace.clearAgentState(journal: harness.center))
            #expect(Set(harness.workspace.statusEntries.keys) == ["build"])
        }
    }
}
