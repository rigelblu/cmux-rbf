public import Foundation

extension WorkspaceGroupCoordinator {
    /// Sets a group's own status and color without modifying members, selection or tab order.
    /// - Parameters:
    ///   - groupId: The target group's identity.
    ///   - action: The explicit status pick; Auto and None both clear.
    ///   - actions: An explicit writer, or nil to use the attached host's current list and palette.
    /// - Returns: Whether the group exists and the pick was accepted.
    @discardableResult
    public func setWorkspaceGroupStatus(
        groupId: UUID,
        action: WorkspaceStatusPickAction,
        actions: WorkspaceGroupStatusActions? = nil
    ) -> Bool {
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return false }
        var group = model.workspaceGroups[index]
        guard (actions ?? currentGroupStatusActions).apply(action, to: &group) else { return false }
        write(group, at: index)
        return true
    }

    /// Restores a saved pair, preserving legacy and currently unlisted statuses without a color pick.
    /// Palette propagation also uses this path: editing a palette entry changes its hex, not the held status.
    /// - Parameters:
    ///   - groupId: The target group's identity.
    ///   - statusId: The status to preserve, including nil.
    ///   - hex: The saved or propagated color, including nil.
    public func restoreWorkspaceGroupStatus(groupId: UUID, statusId: String?, hex: String?) {
        guard let index = model.workspaceGroups.firstIndex(where: { $0.id == groupId }) else { return }
        var group = model.workspaceGroups[index]
        group.statusId = statusId
        group.customColor = hex
        write(group, at: index)
    }

    /// A color pick uses the same pair writer even when the hex itself has not changed (legacy groups have no status).
    func applyWorkspaceGroupColor(at index: Int, hex: String?) {
        var group = model.workspaceGroups[index]
        currentGroupStatusActions.applyColor(hex, to: &group)
        write(group, at: index)
    }

    /// Writes a group the status writers changed, then brings a selection back out of a fold if the group stopped being drawn
    /// under its status (ruling (27), #cm-110.3). The shown set is taken before the write.
    private func write(_ group: WorkspaceGroup, at index: Int) {
        let shownBefore = model.groupIdsShownUnderAStatus()
        if model.workspaceGroups[index] != group { model.workspaceGroups[index] = group }
        model.expandSelectionIfItsGroupLeftItsStatus(shownBefore: shownBefore)
    }

    private var currentGroupStatusActions: WorkspaceGroupStatusActions {
        host?.workspaceGroupStatusActions ?? WorkspaceGroupStatusActions(list: .cmuxFive, resolveColor: { _ in nil })
    }
}
