import CmuxWorkspaces
import Foundation

/// What a workspace holds and shows once its status can be one of his own (#cm-109.2). The hand-overs in
/// `Workspace+Todos.swift` and `Workspace+PanelLifecycle.swift` call into this file.
extension Workspace {
    /// What the workspace shows, worked out from what it holds, for this list. Pure: it changes nothing.
    func statusResolution(list: WorkspaceStatusList) -> WorkspaceStatusResolution {
        WorkspaceStatusResolution.resolve(
            override: todoState.statusOverride,
            own: todoState.ownStatus,
            inferred: inferredTaskStatus,
            list: list
        )
    }

    /// The rows of the Status menu for this workspace against `list`: Auto, one row for each entry, at most one greyed
    /// row, None, each with the action a pick applies and the color the app resolved (`colorHexes`, by id). One call for
    /// a menu that is built when it opens.
    func statusMenuLanes(list: WorkspaceStatusList, colorHexes: [String: String]) -> [WorkspaceTodoStatusLane] {
        let picker = WorkspaceStatusPicker().rows(
            resolution: statusResolution(list: list),
            inferred: inferredTaskStatus,
            isHidden: todoState.statusHidden,
            list: list
        )
        return WorkspaceTodoStatusLane.lanes(picker: picker, colorHexes: colorHexes)
    }

    /// Holds one of his own statuses. Takes only an entry that is not one of cmux's five: a cmux id always goes
    /// through ``setTaskStatusOverride(_:)``, so it is never stored as his own. Returns whether it was set.
    ///
    /// Picked while cmux detects a waiting agent, the status is held through that wait.
    @discardableResult
    func setOwnStatus(_ entry: WorkspaceStatusEntry) -> Bool {
        guard !entry.isCmuxOwn else { return false }
        todoState.statusHidden = false
        todoState.statusOverride = nil
        todoState.ownStatus = WorkspaceOwnStatus(
            id: entry.id,
            heldThroughWait: inferredTaskStatus == .needsAttention
        )
        return true
    }

    /// One press of the cycle key, for this list: works out the target and applies it through the write path, so
    /// the target's color is written like any other pick's.
    func cycleStatusThroughList(actions given: WorkspaceStatusActions? = nil) {
        let actions = given ?? .app()
        let resolution = statusResolution(list: actions.list)
        guard let target = WorkspaceStatusCycle().target(resolution: resolution, list: actions.list) else { return }
        switch target {
        case .entry(let entry):
            actions.apply(.status(id: entry.id), to: [self], requireControls: false)
        case .cmux(let status):
            // The list has no entry for it, so there is no color to write (Decisions, 2026-10-12, point 13).
            setTaskStatusOverride(status)
        }
    }

    /// Runs after every write of an agent's state. Reads no signal unless something waits to be cleared.
    ///
    /// When no agent waits any longer it clears `heldThroughWait` and removes a cmux status that was set during the
    /// wait. One of his own statuses stays. It writes no color.
    func endWaitIfNoAgentWaits() {
        let heldOwn = todoState.ownStatus?.heldThroughWait == true
        let setDuringWait = todoState.statusOverride?.inferredAtOverride == .needsAttention
        guard heldOwn || setDuringWait else { return }
        guard inferredTaskStatus != .needsAttention else { return }
        if heldOwn { todoState.ownStatus?.heldThroughWait = false }
        if setDuringWait { todoState.statusOverride = nil }
    }

    /// Restores his own status from a saved session. An id equal to one of cmux's five is dropped, and his id wins
    /// if a hand-edited file holds both. The list is not asked: a status the list lacks is kept, shows what Auto
    /// shows, and is in effect again the moment the list has it.
    func restoreOwnStatus(from snapshot: SessionWorkspaceSnapshot) {
        guard let id = snapshot.taskStatusOwnID, WorkspaceTaskStatus(rawValue: id) == nil else {
            todoState.ownStatus = nil
            return
        }
        todoState.ownStatus = WorkspaceOwnStatus(id: id)
        todoState.statusOverride = nil
    }
}
