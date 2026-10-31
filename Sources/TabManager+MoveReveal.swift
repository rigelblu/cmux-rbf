import CmuxWorkspaces
import Foundation

// The folds a move opens (#cm-110.14). A workspace someone moves, in the app, from the CLI or an agent, or from the iPhone,
// opens every fold above where it lands, by the rules a workspace switch uses. One reveal serves every entrance: each
// `TabManager` method that moves a workspace calls it once the move is committed, never a function a view's `body` calls.

/// Why a reveal runs. A status, color or cycle move also scrolls the selected workspace into view.
enum MoveRevealCause: Equatable {
    case move
    case status
    case color
    /// One press of the cycle key; `subject` is the workspace or the workspace group it moved.
    case cycle(subject: UUID)

    var scrollsSelected: Bool {
        if case .move = self { return false }
        return true
    }
}

/// Where the status side of the sidebar puts a workspace: its status group or `Pinned`, its color group, its workspace group.
/// A write that leaves it unchanged moves nothing and opens nothing. `colorHex` is the color group the row is drawn in, which a
/// pinned loose row has: a status writes its color, so a status can move a pinned row between pinned color groups (#cm-110.14).
struct SidebarMovePlace: Equatable {
    var statusId: String?
    var isPinned = false
    var colorHex: String?
    var groupId: UUID?

}

/// A window's sidebar side of the reveal, set by `SidebarState.installMoveReveal(on:)`.
struct SidebarMoveReveal {
    let place: @MainActor (Workspace) -> SidebarMovePlace
    /// The last argument is whether the selected workspace is scrolled into view afterwards.
    let reveal: @MainActor (Workspace, MoveRevealCause, Bool) -> Void
}

@MainActor
extension TabManager {
    /// Opens the folds above each workspace that moved: its workspace groups, then, in the sidebar, its status group and the
    /// `Statuses` area, its color group and its `Pinned` or `Workspaces` section.
    func revealMoved(_ ids: [UUID], cause: MoveRevealCause = .move) {
        let moved = ids.compactMap { id in tabs.first { $0.id == id } }
        guard !moved.isEmpty else { return }
        workspaces.expandWorkspaceGroups(containing: moved.map(\.id))
        for workspace in moved {
            let scrolls = cause.scrollsSelected && !isCommittingDrop && selectedTabId == workspace.id
            sidebarMoveReveal?.reveal(workspace, cause, scrolls)
        }
    }

    /// The same for a whole group: the folds above it open, never its own. `opensAbove` is for a group moved into another group.
    func revealMovedGroup(_ groupId: UUID, cause: MoveRevealCause = .move, opensAbove: Bool = false) {
        guard let group = workspaceGroups.first(where: { $0.id == groupId }) else { return }
        if opensAbove { workspaces.expandWorkspaceGroups(above: groupId) }
        let inside = workspaces.workspaceIdsInside(groupId)
        guard let representative = (group.liveAnchorWorkspaceId ?? inside.first).flatMap({ id in tabs.first { $0.id == id } }) else { return }
        let scrolls = cause.scrollsSelected && !isCommittingDrop && (selectedTabId.map(inside.contains) ?? false)
        sidebarMoveReveal?.reveal(representative, cause, scrolls)
    }

    /// Runs a write that can change where workspaces sit (a status, a color) and opens the folds above each one it moved.
    /// A write that leaves a workspace where it was opens nothing.
    @discardableResult
    func revealingMoves<R>(of workspaces: [Workspace], cause: MoveRevealCause, _ write: () -> R) -> R {
        guard let sink = sidebarMoveReveal else { return write() }
        let before = workspaces.map { sink.place($0) }
        let result = write()
        var changed: [UUID] = []
        for (workspace, was) in zip(workspaces, before) where sink.place(workspace) != was { changed.append(workspace.id) }
        revealMoved(changed, cause: cause)
        return result
    }

    /// Where the sidebar draws a group, not what is stored on it (#cm-110.14, fix round 2): a status or a pin written on a nested group
    /// that stays drawn inside its parent moves nothing.
    private struct GroupPlace: Equatable {
        /// The status group it is drawn under, only when it is a status root itself.
        var statusId: String?
        /// The section it is in: the outermost group's pin.
        var isPinned: Bool
        // The group it is drawn inside is not compared: a nested group leaves or enters its parent only when it becomes or stops
        // being a status root, and a root always has a status, so `statusId` already changes with it.
    }

    private func groupPlace(_ groupId: UUID) -> GroupPlace? {
        let groups = workspaceGroups
        guard let group = groups.first(where: { $0.id == groupId }) else { return nil }
        let projection = VerticalTabsSidebar.currentStatusGroupProjection(tabs: tabs, groups: groups)?.workspaceGroups
        let isRoot = projection?.rootGroupIds.contains(groupId) ?? false
        let outermost = WorkspaceGroupTree(groups: groups).outermost(of: groupId)
        return GroupPlace(
            statusId: isRoot ? projection?.statusIdByGroupId[groupId] : nil,
            isPinned: groups.first { $0.id == outermost }?.isPinned ?? group.isPinned
        )
    }

    /// The same, for a write on a whole group (its status, its color, a pin).
    @discardableResult
    func revealingGroupMove<R>(_ groupId: UUID, cause: MoveRevealCause, _ write: () -> R) -> R {
        let before = groupPlace(groupId)
        let result = write()
        // A group that loses its status falls back into its parent, so the folds above it open (#cm-110.14); the walk stops at a group drawn under a status.
        if let after = groupPlace(groupId), after != before { revealMovedGroup(groupId, cause: cause, opensAbove: true) }
        return result
    }

    /// Sets a group's status through the one writer, and opens the folds above where the group lands.
    @discardableResult
    func setWorkspaceGroupStatus(groupId: UUID, action: WorkspaceStatusPickAction, actions: WorkspaceGroupStatusActions? = nil,
                                 cause: MoveRevealCause = .status) -> Bool {
        revealingGroupMove(groupId, cause: cause) {
            workspaceGrouping.setWorkspaceGroupStatus(groupId: groupId, action: action, actions: actions)
        }
    }

    /// Runs a drop's commit: a drop never moves the view, so nothing it moves asks for a scroll.
    @discardableResult
    func committingDrop<R>(_ body: () -> R) -> R {
        let previous = isCommittingDrop
        isCommittingDrop = true
        defer { isCommittingDrop = previous }
        return body()
    }
}
