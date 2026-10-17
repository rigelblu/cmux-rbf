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
    /// Whether an agent in this workspace needs input (waiting on human). Captured from live signals. (#cm-109.4)
    var isAgentWaiting: Bool = false // (#cm-109.4)

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
        let signals = workspace.taskStatusSignals(orderedPanelIds: orderedPanelIds) // (#cm-109.4)
        let inferred = workspace.inferredTaskStatus(list: list, signals: signals) // (#cm-109.4)
        let held = Self.resolution(of: workspace, inferred: inferred, list: list) // (#cm-109)
        let activeOverride: WorkspaceTaskStatus? // (#cm-109.4)
        if case .cmuxInEffect(let entry, _) = held { // (#cm-109.4)
            activeOverride = entry.behavesAs // (#cm-109.4)
        } else { // (#cm-109.4)
            activeOverride = nil // (#cm-109.4)
        } // (#cm-109.4)
        return Self( // (#cm-109.4)
            inferred: inferred, // (#cm-109.4)
            activeOverride: activeOverride, // (#cm-109.4)
            isHidden: workspace.todoState.statusHidden, // (#cm-109.4)
            picker: WorkspaceStatusPicker().rows( // (#cm-109.4)
                resolution: held, // (#cm-109.4)
                inferred: inferred, // (#cm-109.4)
                isHidden: workspace.todoState.statusHidden, // (#cm-109.4)
                list: list // (#cm-109.4)
            ), // (#cm-109.4)
            colorHexes: colorHexes, // (#cm-109.4)
            isAgentWaiting: signals.anyAgentNeedsInput // (#cm-109.4)
        ) // (#cm-109.4)
    }
}
