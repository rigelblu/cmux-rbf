public import Foundation

/// Determines which workspace groups survive session persistence operations
/// (save, restore, and crash snapshot pruning).
///
/// Rule:
/// A group is kept when:
/// 1. A kept workspace names it, or
/// 2. It has no workspace of its own (empty group header), or
/// 3. A kept group names it as parent.
///
/// On restore only, one additional case is kept: a pinned group none of whose
/// workspaces came back. Save and the crash pruner drop it.
public enum WorkspaceGroupPersistenceRule {
    /// A saved group's facts, as the restore and the crash pruner read them.
    public typealias SavedGroup = (id: UUID, parentGroupId: UUID?, anchorIsEmpty: Bool?, isPinned: Bool?)

    private struct Candidate {
        var id: UUID
        var parentGroupId: UUID?
        var hasNoOwnWorkspace: Bool
        var isPinned: Bool
    }

    /// Evaluates which groups are kept for save.
    public static func keptGroupIdsForSave(
        groups: [WorkspaceGroup],
        occupiedGroupIds: Set<UUID>
    ) -> Set<UUID> {
        let candidates = groups.map { group in
            Candidate(
                id: group.id,
                parentGroupId: group.parentGroupId,
                hasNoOwnWorkspace: group.isEmpty,
                isPinned: group.isPinned
            )
        }
        return resolveKeptGroupIds(
            candidates: candidates,
            occupiedGroupIds: occupiedGroupIds,
            keepPinnedWithoutMembers: false
        )
    }

    /// Evaluates which groups are kept for restore.
    public static func keptGroupIdsForRestore(
        saved: [SavedGroup],
        occupiedGroupIds: Set<UUID>
    ) -> Set<UUID> {
        resolveKeptGroupIds(
            candidates: candidates(of: saved),
            occupiedGroupIds: occupiedGroupIds,
            keepPinnedWithoutMembers: true
        )
    }

    /// Evaluates which groups are kept by the crash pruner: the save's rule.
    public static func keptGroupIdsForPruning(
        saved: [SavedGroup],
        occupiedGroupIds: Set<UUID>
    ) -> Set<UUID> {
        resolveKeptGroupIds(
            candidates: candidates(of: saved),
            occupiedGroupIds: occupiedGroupIds,
            keepPinnedWithoutMembers: false
        )
    }

    private static func candidates(of saved: [SavedGroup]) -> [Candidate] {
        saved.map { group in
            Candidate(
                id: group.id,
                parentGroupId: group.parentGroupId,
                hasNoOwnWorkspace: group.anchorIsEmpty == true,
                isPinned: group.isPinned ?? false
            )
        }
    }

    private static func resolveKeptGroupIds(
        candidates: [Candidate],
        occupiedGroupIds: Set<UUID>,
        keepPinnedWithoutMembers: Bool
    ) -> Set<UUID> {
        var kept = Set<UUID>()
        let candidateIds = Set(candidates.map(\.id))

        for candidate in candidates {
            let isOccupied = occupiedGroupIds.contains(candidate.id)
            let isEmptyHeader = candidate.hasNoOwnWorkspace
            let isDurablePinnedEmpty = keepPinnedWithoutMembers && candidate.isPinned && !isOccupied
            if isOccupied || isEmptyHeader || isDurablePinnedEmpty {
                kept.insert(candidate.id)
            }
        }

        // Close under parentGroupId: a kept group keeps its parent, when that
        // parent is one of the candidates. A parent that names no group is not kept.
        var addedAny = true
        while addedAny {
            addedAny = false
            for candidate in candidates {
                if kept.contains(candidate.id),
                   let parent = candidate.parentGroupId,
                   candidateIds.contains(parent),
                   kept.insert(parent).inserted {
                    addedAny = true
                }
            }
        }

        return kept
    }
}
