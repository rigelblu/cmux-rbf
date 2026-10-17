import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Save and restore of a workspace's own status (#cm-109.2), beside `WorkspaceStatusSessionTests`.
@MainActor
@Suite("Workspace status save and restore")
struct WorkspaceStatusRestoreTests {
    private typealias A = WorkspaceStatusActionsTests

    private func blankSnapshot() -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            isPinned: false,
            currentDirectory: "/tmp",
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: []
        )
    }

    private func roundTripped(_ snapshot: SessionWorkspaceSnapshot) throws -> SessionWorkspaceSnapshot {
        try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot))
    }

    @Test func theKeyRoundTripsAndCaptureWritesOnlyHisId() throws {
        let workspace = Workspace()
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        var snapshot = blankSnapshot()
        snapshot.captureTodoState(from: workspace)
        #expect(snapshot.taskStatusOwnID == "parked")
        #expect(snapshot.taskStatusOverride == nil)
        #expect(snapshot.taskStatusInferredAtOverride == nil)

        let again = try roundTripped(snapshot)
        #expect(again.taskStatusOwnID == "parked")
        let restored = Workspace()
        restored.restoreTodoState(from: again)
        #expect(restored.todoState.ownStatus == WorkspaceOwnStatus(id: "parked"))
        #expect(restored.todoState.statusOverride == nil)
        #expect(!restored.todoState.statusHidden)
    }

    @Test func aCmuxStatusIsSavedInTheOldPairAndNoOwnId() throws {
        let workspace = Workspace()
        A.actions().apply(.done, to: [workspace], requireControls: false)
        var snapshot = blankSnapshot()
        snapshot.captureTodoState(from: workspace)
        #expect(snapshot.taskStatusOverride == "done")
        #expect(snapshot.taskStatusOwnID == nil)
        let restored = Workspace()
        restored.restoreTodoState(from: try roundTripped(snapshot))
        #expect(restored.todoState.statusOverride?.status == .done)
        #expect(restored.todoState.ownStatus == nil)
    }

    @Test func aSessionSavedBeforeTheFieldRestoresAsToday() throws {
        var snapshot = blankSnapshot()
        snapshot.taskStatusOverride = "review"
        snapshot.taskStatusInferredAtOverride = "todo"
        let written = try JSONEncoder().encode(snapshot)
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["taskStatusOwnID"] == nil)
        let restored = Workspace()
        restored.restoreTodoState(from: try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: written))
        #expect(restored.todoState.statusOverride?.status == .review)
        #expect(restored.todoState.ownStatus == nil)
    }

    /// A hand-edited file holding both keys: his id wins and the pair is dropped.
    @Test func bothKeysInOneFileKeepOnlyHisId() throws {
        var snapshot = blankSnapshot()
        snapshot.taskStatusOverride = "review"
        snapshot.taskStatusInferredAtOverride = "todo"
        snapshot.taskStatusOwnID = "parked"
        let restored = Workspace()
        restored.restoreTodoState(from: try roundTripped(snapshot))
        #expect(restored.todoState.ownStatus?.id == "parked")
        #expect(restored.todoState.statusOverride == nil)
    }

    @Test func anIdEqualToOneOfCmuxsFiveIsDroppedAndThePairStays() throws {
        var snapshot = blankSnapshot()
        snapshot.taskStatusOverride = "review"
        snapshot.taskStatusInferredAtOverride = "todo"
        snapshot.taskStatusOwnID = "done"
        let restored = Workspace()
        restored.restoreTodoState(from: snapshot)
        #expect(restored.todoState.ownStatus == nil)
        #expect(restored.todoState.statusOverride?.status == .review)
    }

    /// Restore does not ask whether the list has the id: a status the list lacks is kept, shows what Auto shows, and
    /// is in effect again the moment the list has it.
    @Test func restoreKeepsAnIdTheListDoesNotHave() throws {
        var snapshot = blankSnapshot()
        snapshot.taskStatusOwnID = "parked"
        let restored = Workspace()
        restored.restoreTodoState(from: snapshot)
        let lacking = WorkspaceStatusList(entries: [A.hisEntries[0]], source: .file)
        #expect(restored.todoState.ownStatus?.id == "parked")
        #expect(restored.statusResolution(list: lacking).held == .notListed)
        #expect(restored.statusResolution(list: A.hisList).held == .inEffect)
        #expect(restored.statusResolution(list: .cmuxFive).held == .notListed)
    }

    /// A saved session that holds his id and None restores to both: the one writer of the table that keeps a held
    /// status beside None (Decisions, 2026-10-12, point 14, "only through a saved session that holds both").
    @Test func aSessionWithHisIdAndNoneRestoresToBoth() throws {
        var snapshot = blankSnapshot()
        snapshot.taskStatusOwnID = "parked"
        snapshot.taskStatusHidden = true
        let restored = Workspace()
        restored.restoreTodoState(from: try roundTripped(snapshot))
        #expect(restored.todoState.ownStatus?.id == "parked")
        #expect(restored.todoState.statusHidden)
        #expect(restored.todoState.statusOverride == nil)
    }

    @Test func hisStatusIsSavedAndRestored() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: "claude_code", panelId: panelId, lifecycle: .needsInput)
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        var snapshot = blankSnapshot()
        snapshot.captureTodoState(from: workspace)
        let restored = Workspace()
        restored.restoreTodoState(from: try roundTripped(snapshot))
        #expect(restored.todoState.ownStatus == WorkspaceOwnStatus(id: "parked"))
    }

    @Test func aChangeOfHisStatusChangesTheAutosaveFingerprint() {
        func fingerprint(_ workspace: Workspace) -> Int {
            var hasher = Hasher()
            workspace.combineTodoStateIntoSessionAutosaveFingerprint(into: &hasher)
            return hasher.finalize()
        }
        let workspace = Workspace()
        let before = fingerprint(workspace)
        #expect(fingerprint(workspace) == before)
        A.actions().apply(.status(id: "parked"), to: [workspace], requireControls: false)
        let parked = fingerprint(workspace)
        #expect(parked != before)
        A.actions().apply(.status(id: "doing"), to: [workspace], requireControls: false)
        #expect(fingerprint(workspace) != parked)
    }
}
