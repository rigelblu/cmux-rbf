import CmuxWorkspaces
import Foundation

/// Status-menu inputs belong to the same cached workspace projection as its
/// visible row. Selection, hover and catalog updates must not re-walk panes.
struct SidebarWorkspaceTaskStatusSnapshot: Equatable {
    var inferred: WorkspaceTaskStatus = .todo
    var activeOverride: WorkspaceTaskStatus?
    var isHidden = false
    /// Every row a picker draws, as one value, worked out against the list in use. `nil` for a snapshot made with no
    /// list (the snapshot builder makes one with no arguments), which gets no status rows. (#cm-109)
    var picker: WorkspaceStatusPickerState?
    /// The color the app resolved for each status of the list, by id, for the rows' dots. Taken from the store by the
    /// parent that builds the snapshot; a row never reads the store. (#cm-109)
    var colorHexes: [String: String] = [:]

    /// What a workspace shows against `list`, worked out from what it holds and what cmux detects. One function for
    /// the factory and for `capture`, so the glyph and the picker's rows come from one read of the list. (#cm-109)
    @MainActor
    static func resolution(of workspace: Workspace, inferred: WorkspaceTaskStatus, list: WorkspaceStatusList) -> WorkspaceStatusResolution {
        WorkspaceStatusResolution.resolve(
            override: workspace.todoState.statusOverride,
            own: workspace.todoState.ownStatus,
            inferred: inferred,
            list: list
        )
    }

    @MainActor
    static func capture(
        workspace: Workspace,
        orderedPanelIds: [UUID],
        list: WorkspaceStatusList,
        colorHexes: [String: String] = [:]
    ) -> Self {
        let inferred = WorkspaceTaskStatus.inferred(from: workspace.taskStatusSignals(orderedPanelIds: orderedPanelIds))
        let override = workspace.todoState.statusOverride
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(override: override, inferred: inferred)
        let held = Self.resolution(of: workspace, inferred: inferred, list: list) // (#cm-109)
        return Self(
            inferred: inferred,
            activeOverride: resolution.shouldClearOverride ? nil : override?.status,
            isHidden: workspace.todoState.statusHidden,
            picker: WorkspaceStatusPicker().rows(
                resolution: held,
                inferred: inferred,
                isHidden: workspace.todoState.statusHidden,
                list: list
            ),
            colorHexes: colorHexes
        )
    }
}
