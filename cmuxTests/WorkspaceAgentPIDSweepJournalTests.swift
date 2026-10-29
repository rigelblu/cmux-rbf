import CmuxAgentJournal
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceAgentPIDSweepJournalTests {
    /// Returns once the center has processed everything it was handed before this call: its operations run in order, and
    /// `admitNotification` completes only after its own draft is processed. No sleeping and no polling, so a slow machine
    /// cannot make a missing write look absent. The barrier's own event is in the store afterwards, under `barrierSession`.
    private static let barrierSession = "barrier"

    private func settle(_ journal: AgentJournalLifecycleCenter) async {
        _ = await journal.admitNotification(AgentJournalEventDraft(kind: .stateChanged, occurredAtMs: 1,
            source: "claude", agentKey: "claude_code", sessionId: Self.barrierSession,
            workspaceId: UUID().uuidString, surfaceId: UUID().uuidString, nativeEvent: "Barrier"))
    }

    private func events(_ fixture: AgentJournalLivenessTestFixture) throws -> [AgentJournalEvent] {
        try fixture.store.events(afterSequence: 0, limit: 20).filter { $0.draft.sessionId != Self.barrierSession }
    }

    @Test(arguments: [false, true], ["claude", "codex"])
    func deadPIDEndsItsExactSessionInBothSweeps(panelOnly: Bool, source: String) async throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let fixture = try AgentJournalLivenessTestFixture(source: source, workspace: workspace.id, surface: panel)
        try fixture.record(pid: 999_999, workspace: workspace.id, surface: panel)
        let journal = AgentJournalLifecycleCenter(databaseURL: fixture.databaseURL)
        let pidKey = source == "claude" ? "claude_code" : "codex.\(fixture.session)"
        workspace.recordAgentPID(key: pidKey, pid: 999_999, panelId: panel, refreshPorts: false)
        let changed = panelOnly
            ? workspace.clearStaleAgentPIDs(panelId: panel, refreshPorts: false, journal: journal, liveness: fixture.resolver)
            : workspace.clearStaleAgentPIDs(refreshPorts: false, journal: journal, liveness: fixture.resolver)
        #expect(changed)
        await settle(journal)
        let journaled = try events(fixture)
        #expect(journaled.count == 2)
        let ended = try #require(journaled.last)
        #expect(ended.kind == .sessionEnded)
        #expect(ended.draft.source == source)
        #expect(ended.draft.sessionId == fixture.session)
        #expect(ended.draft.nativeEvent == "PIDProcessGone")
        #expect(fixture.replay().assignments.isEmpty)
        #expect(workspace.agentPIDs[pidKey] == nil)
    }

    /// The PID is present, but the recorded start time is another generation's: the old agent is gone.
    @Test(arguments: [false, true])
    func presentPIDOfAnotherGenerationEndsItsSession(panelOnly: Bool) async throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let fixture = try AgentJournalLivenessTestFixture(source: "codex", workspace: workspace.id, surface: panel)
        let journal = AgentJournalLifecycleCenter(databaseURL: fixture.databaseURL)
        let key = "codex.\(fixture.session)"
        workspace.recordAgentPID(key: key, pid: getpid(), panelId: panel, refreshPorts: false)
        let current = try #require(workspace.agentPIDProcessIdentitiesByKey[key])
        workspace.agentPIDProcessIdentitiesByKey[key] = AgentPIDProcessIdentity(
            pid: getpid(), startSeconds: current.startSeconds - 1, startMicroseconds: current.startMicroseconds)
        let changed = panelOnly
            ? workspace.clearStaleAgentPIDs(panelId: panel, refreshPorts: false, journal: journal, liveness: fixture.resolver)
            : workspace.clearStaleAgentPIDs(refreshPorts: false, journal: journal, liveness: fixture.resolver)
        #expect(changed)
        await settle(journal)
        let ended = try #require(try events(fixture).last)
        #expect(try events(fixture).count == 2)
        #expect(ended.kind == .sessionEnded)
        #expect(ended.draft.sessionId == fixture.session)
        #expect(ended.draft.nativeEvent == "PIDProcessGone")
    }

    /// With no recorded start time a present PID is unproven: the sweep clears its own entry and the journal keeps the wait.
    @Test func presentPIDWithNoRecordedStartTimeIsClearedButNotEnded() async throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let fixture = try AgentJournalLivenessTestFixture(source: "codex", workspace: workspace.id, surface: panel)
        let journal = AgentJournalLifecycleCenter(databaseURL: fixture.databaseURL)
        let key = "codex.\(fixture.session)"
        workspace.recordAgentPID(key: key, pid: getpid(), panelId: panel, refreshPorts: false)
        workspace.agentPIDProcessIdentitiesByKey[key] = nil
        #expect(workspace.clearStaleAgentPIDs(refreshPorts: false, journal: journal, liveness: fixture.resolver))
        await settle(journal)
        #expect(try events(fixture).count == 1, "the sweep journaled nothing for an unproven PID")
    }

    @Test func livePIDIsNeverEnded() async throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedPanelId)
        let fixture = try AgentJournalLivenessTestFixture(source: "codex", workspace: workspace.id, surface: panel)
        let journal = AgentJournalLifecycleCenter(databaseURL: fixture.databaseURL)
        let key = "codex.\(fixture.session)"
        workspace.recordAgentPID(key: key, pid: getpid(), panelId: panel, refreshPorts: false)
        #expect(!workspace.clearStaleAgentPIDs(refreshPorts: false, journal: journal, liveness: fixture.resolver))
        await settle(journal)
        #expect(try events(fixture).count == 1)
    }
}
