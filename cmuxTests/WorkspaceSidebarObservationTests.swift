import Combine
import Foundation
import Observation
import Testing

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceSidebarObservationTests {
    @Test func sidebarObservationPublisherEmitsForLateStatusSubscriber() {
        let workspace = Workspace()
        workspace.statusEntries["test_probe"] = SidebarStatusEntry(
            key: "test_probe",
            value: "VISIBLE?",
            icon: "star.fill",
            color: "#FF0000",
            priority: 200
        )

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after status metadata already exists must still refresh from the current workspace state."
        )
    }

    @Test func agentRuntimeObservationChangesWhenAgentPIDMakesExistingStatusVisible() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.statusEntries["codex"] = SidebarStatusEntry(
            key: "codex",
            value: "Running",
            icon: "bolt.fill",
            color: "#4C8DFF"
        )
        #expect(
            !workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Structured agent statuses stay hidden until a live agent runtime owns the status key."
        )

        let generationBeforeRecord = workspace.sidebarAgentRuntimeObservation.changeGeneration
        var workspaceWillChangeCount = 0
        let objectWillChangeCancellable = workspace.objectWillChange.sink {
            workspaceWillChangeCount += 1
        }
        defer { objectWillChangeCancellable.cancel() }

        workspace.recordAgentPID(
            key: "codex.session-b",
            pid: 12_345,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            workspace.sidebarStatusEntriesInDisplayOrder().contains { $0.key == "codex" },
            "Recording the agent PID makes the existing Running status visible."
        )
        #expect(
            workspace.sidebarAgentRuntimeObservation.changeGeneration > generationBeforeRecord,
            "Agent PID ownership changes must notify the sidebar row runtime observation stream."
        )
        #expect(
            workspaceWillChangeCount == 0,
            "Agent PID ownership is sidebar presentation state and must not broadly invalidate Workspace observers."
        )
    }

    @Test func terminalAgentContextDoesNotObserveAgentRuntimeMaps() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let panel = try #require(workspace.panels[panelId])
        let changeFlag = ObservationChangeFlag()

        withObservationTracking {
            _ = WorkspaceContentView.terminalAgentContext(panel: panel, workspace: workspace)
        } onChange: {
            changeFlag.mark()
        }

        workspace.recordAgentPID(
            key: "codex.session-c",
            pid: 12_346,
            panelId: panelId,
            refreshPorts: false
        )

        #expect(
            changeFlag.fired == false,
            "Terminal content must not subscribe to sidebar-only agent runtime map churn."
        )
    }

    @Test func sidebarImmediateObservationPublisherEmitsForLateTitleSubscriber() {
        let workspace = Workspace()
        workspace.title = "Restored Workspace"

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        #expect(
            publishCount > 0,
            "A sidebar row that subscribes after immediate workspace fields already exist must still refresh from the current workspace state."
        )
    }

    @Test func sidebarImmediateObservationPublisherDeliversManualTitleChangeSynchronously() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.setCustomTitle("User Edit")

        #expect(
            publishCount == 1,
            "The first immediate-field change after subscribing must reach the sidebar in the same run-loop turn; coalescing may only defer the tail of a burst."
        )
    }

    @Test func sidebarImmediateObservationPublisherCoalescesDescriptionBursts() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarImmediateObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        for turn in 0..<20 {
            workspace.customDescription = "Agent Turn \(turn)"
        }

        #expect(
            publishCount == 1,
            "A synchronous burst of immediate fields must deliver only its leading edge immediately."
        )

        // Generous pump so the 50ms trailing emission fires deterministically.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))

        #expect(
            publishCount == 2,
            "A coalesced burst must settle with exactly one trailing emission carrying the latest state."
        )
    }

    @Test func coalesceLatestKeepsLeadingEdgeSynchronousAndEmitsLatestTrailing() {
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        // First value models the @Published current-state replay: forwarded
        // synchronously without opening a coalesce window.
        subject.send(1)
        #expect(received == [1])

        // First change is the synchronous leading edge and opens the window.
        subject.send(2)
        #expect(received == [1, 2])

        // Burst inside the window coalesces to the latest value.
        subject.send(3)
        subject.send(4)
        subject.send(5)
        #expect(received == [1, 2])

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        #expect(received == [1, 2, 5])

        // After the window closes and the trailing window expires, the next
        // value is synchronous again.
        subject.send(6)
        #expect(received == [1, 2, 5, 6])
    }

    @Test func coalesceLatestDropsStalePendingValueWhenLeadingSupersedesOverdueTrailing() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        var received: [Int] = []
        let cancellable = subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .sink { received.append($0) }
        defer { cancellable.cancel() }

        subject.send(1) // replay: forwarded, no window
        subject.send(2) // leading edge: opens window
        subject.send(3) // pending trailing value for the open window
        #expect(received == [1, 2])
        #expect(scheduler.scheduledActionCount == 1)

        // The deadline passes WITHOUT the scheduled callback running,
        // modeling a stalled main run loop with an overdue timer.
        scheduler.advance(by: 0.12)
        subject.send(4) // deadline passed: new leading edge must supersede 3

        #expect(
            received == [1, 2, 4],
            "A newer leading value after an overdue deadline must drop the stale pending value."
        )

        scheduler.runScheduledActions()
        #expect(
            received == [1, 2, 4],
            "The overdue trailing callback must not emit the superseded stale value out of order."
        )
    }

    @Test func coalesceLatestDrainsReentrantValueBeforeCompletionWithUnlimitedDemand() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        let subscriber = DemandControlledSubscriber<Int>()
        subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .subscribe(subscriber)
        defer { subscriber.cancel() }

        subscriber.onValue = { value in
            if value == 1 {
                subject.send(2)
                subject.send(completion: .finished)
            }
        }
        subscriber.request(.unlimited)
        subject.send(1)

        #expect(
            subscriber.received == [1, 2],
            "A reentrant value that arrived before completion must drain while unlimited demand remains."
        )
        #expect(subscriber.completionCount == 1)
        #expect(subscriber.receivedValuesAtCompletion == [[1, 2]])
    }

    @Test func coalesceLatestDeliversBufferedValueBeforeCompletionWhenDemandResumes() {
        let scheduler = VirtualCoalesceScheduler()
        let subject = PassthroughSubject<Int, Never>()
        let subscriber = DemandControlledSubscriber<Int>()
        subject
            .coalesceLatest(for: .milliseconds(50), scheduler: scheduler)
            .subscribe(subscriber)
        defer { subscriber.cancel() }

        subject.send(1)
        subject.send(completion: .finished)

        #expect(subscriber.received.isEmpty)
        #expect(
            subscriber.completionCount == 0,
            "Completion must wait while the final value is buffered without demand."
        )

        subscriber.request(.max(1))

        #expect(subscriber.received == [1])
        #expect(subscriber.completionCount == 1)
        #expect(subscriber.receivedValuesAtCompletion == [[1]])
    }

    @Test func sidebarObservationPublisherIgnoresRemoteHeartbeatOnlyChanges() {
        let workspace = Workspace()

        var publishCount = 0
        let cancellable = workspace.sidebarObservationPublisher.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }
        publishCount = 0

        workspace.remoteHeartbeatCount = 1
        workspace.remoteLastHeartbeatAt = Date()

        #expect(
            publishCount == 0,
            "Expected non-visible remote heartbeat updates to avoid invalidating sidebar rows"
        )
    }

    @Test func agentLifecycleChangeBumpsRuntimeObservationGeneration() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        let before = workspace.sidebarAgentRuntimeObservation.changeGeneration

        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(
            workspace.sidebarAgentRuntimeObservation.changeGeneration > before,
            "Agent lifecycle changes must notify sidebar rows so the loading spinner updates."
        )
    }

    @Test func redundantAgentLifecycleWriteDoesNotNotifySidebarRows() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        let before = workspace.sidebarAgentRuntimeObservation.changeGeneration

        // Re-asserting the same lifecycle value must not churn row refreshes.
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)

        #expect(workspace.sidebarAgentRuntimeObservation.changeGeneration == before)
    }

    @Test func clearAgentLifecycleWithNilPanelClearsKeySetOnSpecificPanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)
        #expect(
            spinnerCount(workspace) == 1 // cmux-rbf: changed on purpose (#cm-128.6)
        )

        // The workspace-scoped `cmux workspace loading off` path clears with a
        // nil panel id; it must remove the key even though `on` targeted a
        // specific panel (the cross-surface off bug).
        #expect(workspace.clearAgentLifecycle(key: "manual", panelId: nil))
        #expect(
            spinnerCount(workspace) == 0 // cmux-rbf: changed on purpose (#cm-128.6)
        )
    }

    @Test func runningLifecycleQueryIsScopedToOneLoaderKey() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)

        #expect(workspace.hasRunningAgentLifecycle(key: "manual"))
        #expect(workspace.clearAgentLifecycle(key: "manual", panelId: nil))
        #expect(!workspace.hasRunningAgentLifecycle(key: "manual"))
        #expect(workspace.hasRunningAgentLifecycle(key: "codex"))
        #expect(
            spinnerCount(workspace) == 1 // cmux-rbf: changed on purpose (#cm-128.6)
        )
    }

    @Test func clearAgentLifecycleStatesPreservesManualLoadersOnLivePanel() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "codex", panelId: panelId, lifecycle: .running)
        workspace.setAgentLifecycle(key: "manual", panelId: panelId, lifecycle: .running)

        // Agent lifecycle resets clear agent keys but must not drop the
        // workspace-scoped manual loader with them.
        workspace.clearAgentLifecycleStates(panelId: panelId)

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["codex"] == nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?["manual"] == .running)
    }

    // cmux-rbf: changed on purpose (#cm-128.6): the spinner's count as the row computes it, through the lists (the old per-key counter is gone).
    private func spinnerCount(_ workspace: Workspace) -> Int {
        SidebarAgentActivitySummary.lists(
            showsNeedsYouMarks: true, showsAgentActivity: true,
            paneStates: workspace.agentPaneStates(panelIds: Array(workspace.agentLifecycleStatesByPanelId.keys))
        ).activeCodingAgentCount
    }

    // cmux-rbf: changed on purpose (#cm-128.6): the per-key counter is gone; the lists count the running panes.
    @Test func activeCodingAgentCountOnlyCountsRunningAgents() {
        let firstPanelId = UUID()
        let secondPanelId = UUID()
        func pane(_ panel: UUID, _ key: String, _ state: AgentHibernationLifecycleState) -> WorkspaceAgentPaneState {
            WorkspaceAgentPaneState(panelId: panel, agentKey: key, state: state, usageLimit: false)
        }
        let lists = SidebarAgentActivitySummary.lists(
            showsNeedsYouMarks: true, showsAgentActivity: true,
            paneStates: WorkspaceAgentPaneStates(entries: [
                pane(firstPanelId, "codex", .running), pane(firstPanelId, "claude_code", .idle),
                pane(firstPanelId, "gemini", .needsInput), pane(secondPanelId, "opencode", .running),
                pane(secondPanelId, "kiro", .unknown),
            ]))

        #expect(lists.activeCodingAgentCount == 2)
    }

    // cmux-rbf: changed on purpose (#cm-128.6): the gate is the lists builder's, which is the code that ships.
    @Test func theSpinnerCountIsZeroWhenAgentActivityIsDisabled() {
        let panelId = UUID()
        let states = WorkspaceAgentPaneStates(entries: [
            WorkspaceAgentPaneState(panelId: panelId, agentKey: "codex", state: .running, usageLimit: false),
            WorkspaceAgentPaneState(panelId: panelId, agentKey: "claude_code", state: .running, usageLimit: false),
        ])

        #expect(SidebarAgentActivitySummary.lists(
            showsNeedsYouMarks: true, showsAgentActivity: false, paneStates: states).activeCodingAgentCount == 0)
        #expect(SidebarAgentActivitySummary.lists(
            showsNeedsYouMarks: true, showsAgentActivity: true, paneStates: states).activeCodingAgentCount == 2)
    }
}

// Mutable flag captured by Observation's Sendable onChange closure in this test.
private final class ObservationChangeFlag: @unchecked Sendable {
    private(set) var fired = false

    func mark() {
        fired = true
    }
}

private final class DemandControlledSubscriber<Input>: Subscriber {
    typealias Failure = Never

    private var subscription: Subscription?
    private(set) var received: [Input] = []
    private(set) var completionCount = 0
    private(set) var receivedValuesAtCompletion: [[Input]] = []
    var onValue: ((Input) -> Void)?

    func receive(subscription: Subscription) {
        self.subscription = subscription
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        received.append(input)
        onValue?(input)
        return .none
    }

    func receive(completion: Subscribers.Completion<Never>) {
        completionCount += 1
        receivedValuesAtCompletion.append(received)
    }

    func request(_ demand: Subscribers.Demand) {
        subscription?.request(demand)
    }

    func cancel() {
        subscription?.cancel()
        subscription = nil
    }
}
// Deterministic Combine scheduler for coalesceLatest tests: `now` only moves
// via advance(by:), and scheduled actions run only when runScheduledActions()
// is called, so overdue-timer interleavings are exact instead of wall-clock.
private final class VirtualCoalesceScheduler: Scheduler {
    typealias SchedulerTimeType = RunLoop.SchedulerTimeType
    typealias SchedulerOptions = Never

    private(set) var now = SchedulerTimeType(Date(timeIntervalSinceReferenceDate: 0))
    var minimumTolerance: SchedulerTimeType.Stride { .seconds(0) }
    private var scheduledActions: [() -> Void] = []

    var scheduledActionCount: Int { scheduledActions.count }

    func advance(by seconds: TimeInterval) {
        now = SchedulerTimeType(now.date.addingTimeInterval(seconds))
    }

    func runScheduledActions() {
        let actions = scheduledActions
        scheduledActions = []
        actions.forEach { $0() }
    }

    func schedule(options: Never?, _ action: @escaping () -> Void) {
        action()
    }

    func schedule(
        after date: SchedulerTimeType,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) {
        scheduledActions.append(action)
    }

    func schedule(
        after date: SchedulerTimeType,
        interval: SchedulerTimeType.Stride,
        tolerance: SchedulerTimeType.Stride,
        options: Never?,
        _ action: @escaping () -> Void
    ) -> Cancellable {
        scheduledActions.append(action)
        return AnyCancellable {}
    }
}
