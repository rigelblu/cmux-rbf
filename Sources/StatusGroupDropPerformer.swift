import CmuxFoundation
import CmuxWorkspaces
import Foundation

/// A status drop uses the shared status/color action once, then places the dragged member in fresh slots.
@MainActor
struct StatusGroupDropPerformer {
    let statusActions: WorkspaceStatusActions
    let currentProjection: () -> WorkspaceStatusGroupProjection?
    let reorder: (UUID, UUID, Bool, [UUID]) -> Bool

    func perform(_ plan: SidebarStatusGroupWorkspaceDropPlan, dragged: Workspace,
                 sourceKind: SidebarStatusGroupDropRules.SourceKind) -> Bool {
        guard sourceKind == .workspace, statusActions.controlsEnabled,
              statusActions.list.source != .cmux, !statusActions.list.entries.isEmpty,
              statusActions.list.entry(id: plan.statusId) != nil,
              let before = currentProjection()?.group(for: plan.statusId) else { return false }
        if case .member(let target, _) = plan.placement,
           !before.memberWorkspaceIds.contains(target) { return false }
        let alreadyMember = before.memberWorkspaceIds.contains(dragged.id)
        guard plan.setsStatus || alreadyMember else { return false }
        if !alreadyMember {
            guard statusActions.apply(.status(id: plan.statusId), to: [dragged], requireControls: true) == .set else { return false }
        }
        if dragged.isPinned || dragged.groupId != nil { return true }
        guard let fresh = currentProjection()?.group(for: plan.statusId),
              fresh.memberWorkspaceIds.contains(dragged.id) else { return false }
        let target: UUID, insertBefore: Bool
        switch plan.placement {
        case .first:
            guard let first = fresh.memberWorkspaceIds.first(where: { $0 != dragged.id }) else { return true }
            target = first; insertBefore = true
        case .member(let id, let before): target = id; insertBefore = before
        }
        if target == dragged.id { return true }
        var placed = fresh.memberWorkspaceIds.filter { $0 != dragged.id }
        guard let index = placed.firstIndex(of: target) else { return false }
        placed.insert(dragged.id, at: index + (insertBefore ? 0 : 1))
        return reorder(dragged.id, target, insertBefore, fresh.memberWorkspaceIds) || placed == fresh.memberWorkspaceIds
    }
}
