import CmuxAgentJournal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A restore that meets an open pane must not move that pane's agent state to the restored copy (`cm-128.19`).
@MainActor
@Suite("Restore aliases are live-first", .serialized)
struct RestoreAliasLiveFirstTests {
    // Scenario 225: `canonicalized` asks the real terminal registry, not a stub.
    @Test func canonicalizedKeepsALiveOldIdAndFollowsADeadOnesAlias() throws {
        let workspace = Workspace()
        defer { workspace.teardownAllPanels() }
        let live = try #require(workspace.focusedPanelId)
        let dead = UUID()
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: live) != nil)
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: dead) == nil)
        let liveTarget = UUID().uuidString
        let deadTarget = UUID().uuidString
        let aliases = AgentJournalAliasResolver(surfaces: [
            live.uuidString: liveTarget,
            dead.uuidString: deadTarget,
        ])

        func event(on surfaceId: UUID) -> AgentJournalEvent {
            AgentJournalEvent(sequence: 1, committedAtMs: 1, draft: AgentJournalEventDraft(
                kind: .turnStarted, occurredAtMs: 1, source: "claude", agentKey: "claude_code",
                sessionId: "session", workspaceId: workspace.id.uuidString, surfaceId: surfaceId.uuidString))
        }
        let kept = AgentJournalLifecycleCenter.canonicalized(event(on: live), aliases: aliases)
        let followed = AgentJournalLifecycleCenter.canonicalized(event(on: dead), aliases: aliases)
        #expect(kept.draft.surfaceId == live.uuidString)
        #expect(followed.draft.surfaceId == deadTarget)
    }

    // Scenario 220: the record guard.
    @Test func restoreOverAnOpenPaneRecordsNoAliasForIt() async throws {
        let source = Workspace()
        defer { source.teardownAllPanels() }
        let sourcePanel = try #require(source.focusedPanelId)
        let snapshot = source.sessionSnapshot(includeScrollback: false)

        let restored = Workspace()
        defer { restored.teardownAllPanels() }
        let ids = restored.restoreSessionSnapshot(snapshot)
        let restoredPanel = try #require(ids[sourcePanel])
        #expect(restoredPanel != sourcePanel)

        let maps = try await recordedAliases(source: source, restored: restored, ids: ids)
        #expect(maps.surfaces[sourcePanel.uuidString] == nil)
    }

    @Test func restoreOfAFreeIdReusesItAndRecordsNoAliasEither() async throws {
        let source = Workspace()
        let sourcePanel = try #require(source.focusedPanelId)
        let snapshot = source.sessionSnapshot(includeScrollback: false)
        source.teardownAllPanels()
        #expect(GhosttyApp.terminalSurfaceRegistry.surface(id: sourcePanel) == nil)

        let restored = Workspace()
        defer { restored.teardownAllPanels() }
        let ids = restored.restoreSessionSnapshot(snapshot)
        #expect(ids[sourcePanel] == sourcePanel)
        #expect(restored.terminalPanel(for: sourcePanel) != nil)

        let maps = try await recordedAliases(source: source, restored: restored, ids: ids)
        #expect(maps.surfaces[sourcePanel.uuidString] == nil)
    }

    /// Hands the restore's id map to a center built on its own store, then waits for its worker.
    /// The worker handles operations in order, so a later append reaching the store means the aliases were handled.
    private func recordedAliases(
        source: Workspace,
        restored: Workspace,
        ids: [UUID: UUID]
    ) async throws -> (workspaces: [String: String], surfaces: [String: String]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-alias-live-first-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("journal.sqlite3")
        let center = AgentJournalLifecycleCenter(databaseURL: url)
        center.noteRestoredIdentityAliases(
            oldWorkspaceId: source.id, newWorkspaceId: restored.id, oldToNewPanelIds: ids)
        center.enqueueAppend(AgentJournalEventDraft(
            kind: .stateChanged, occurredAtMs: 1, source: "claude", agentKey: "claude_code",
            sessionId: "barrier", workspaceId: UUID().uuidString, surfaceId: UUID().uuidString))
        // The center's own store: a second connection races the worker's WAL setup ("database is locked").
        // Off the main actor, because opening the journal can migrate.
        return try await Task.detached {
            let store = try #require(center.journalStoreForTesting())
            let deadline = Date().addingTimeInterval(10)
            while try store.headSequence() < 1 {
                try #require(Date() < deadline, "the journal worker never reached the barrier event")
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            return try store.aliasMaps()
        }.value
    }
}
